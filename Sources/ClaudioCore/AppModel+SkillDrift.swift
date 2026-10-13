import Foundation

// Step 5b of the Project Assistant: skills edited outside Claudio (drift).
// `--add-dir` lets sessions write to Claudio's skills, and anyone can edit
// a skill saved to the repository. Every 15 s, in every mode, each approved
// skill's file is checked: by size and date first, and read and hashed only
// when those changed. One whose text no longer matches what Claudio
// approved (or wrote), or that's gone, becomes a Needs You card. Claudio's
// own writes (Approve, Revert, Keep Change, Save to Repository) update the
// stored hash in the same step, so they never look like an outside edit.

extension AppModel {
    // MARK: - Finding them

    /// Checks each approved skill Claudio manages (its own, and those it
    /// saved to the repository) against the text it approved.
    func checkSkillDrift() {
        for project in workspace.projects where !unreadableSkillsData.contains(project.id) {
            let records = skillsData(inProject: project.id).records.filter { $0.location != .retired }
            for record in records {
                guard let url = skillFileURL(record.name, location: record.location, projectID: project.id) else { continue }
                checkDrift(of: record, at: url, projectID: project.id)
            }
        }
    }

    /// Where a skill's file is: Claudio's root, or the repository's main checkout.
    func skillFileURL(_ name: String, location: SkillLocation, projectID: UUID) -> URL? {
        guard SkillName.isValid(name) else { return nil }
        switch location {
        case .claudio: return assistantStore.approvedSkillFile(name: name, projectID: projectID)
        case .repository:
            guard let project = workspace.project(projectID) else { return nil }
            return URL(fileURLWithPath: project.path).appendingPathComponent(AppModel.repositorySkillPath(name))
        case .retired: return nil
        }
    }

    private func checkDrift(of record: SkillRecord, at url: URL, projectID: UUID) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = attributes.map { "\(($0[.size] as? NSNumber)?.int64Value ?? -1)@\(($0[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" }
            ?? "gone"
        let key = AppModel.skillFileStampKey(record.name, location: record.location, projectID: projectID)
        guard skillFileStamps[key] != stamp else { return }
        // A file that can't be read just now isn't taken to be gone.
        let text: String?
        if attributes == nil {
            text = nil
        } else if let read = try? String(contentsOf: url, encoding: .utf8) {
            text = read
        } else {
            return
        }
        skillFileStamps[key] = stamp
        let hash = text.map(SkillText.hash)
        let open = skillsData(inProject: projectID).outsideEdits.first { $0.name == record.name && $0.location == record.location }
        guard hash != record.contentHash else {
            // Back as it was (put back by hand, say): nothing to ask.
            skillFileEditors[AppModel.resolvedPath(url)] = nil
            if let open { updateSkillsData(projectID) { $0.outsideEdits.removeAll { $0.id == open.id } } }
            return
        }
        guard open?.foundHash != hash || open?.deleted != (text == nil) else { return }
        let path = AppModel.resolvedPath(url)
        let editor = skillFileEditors[path]
        // Used once: a later edit by hand (or by Bash) isn't blamed on it.
        skillFileEditors[path] = nil
        let edit = OutsideEdit(name: record.name, location: record.location, deleted: text == nil, foundHash: hash, foundAt: now(),
                               editorSessionID: editor, editorName: editor.flatMap { workspace.session($0)?.name })
        updateSkillsData(projectID) { data in
            data.outsideEdits.removeAll { $0.name == record.name && $0.location == record.location }
            data.outsideEdits.append(edit)
        }
        log.append(.info, "\(record.name) was \(text == nil ? "deleted" : "changed") outside Claudio"
                   + (edit.editorName.map { " (by \($0))" } ?? ""))
    }

    static func skillFileStampKey(_ name: String, location: SkillLocation, projectID: UUID) -> String {
        "\(projectID.uuidString):\(location.rawValue):\(name)"
    }

    /// After Claudio writes (or removes) a skill's file itself: the next
    /// check reads it afresh, so what it remembered from before (such as
    /// "gone", before a Restore) can't hide a later change.
    func forgetSkillFileStamps(_ name: String, projectID: UUID) {
        for location in [SkillLocation.claudio, .repository] {
            skillFileStamps[AppModel.skillFileStampKey(name, location: location, projectID: projectID)] = nil
            // Claudio wrote it: whoever edited it before isn't who changes it next.
            if let url = skillFileURL(name, location: location, projectID: projectID) {
                skillFileEditors[AppModel.resolvedPath(url)] = nil
            }
        }
    }

    /// A path with links resolved, so an edit made through a session's own
    /// skill set (a link to the approved folder) matches the approved file.
    static func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A session's Edit or Write of a skill file: remembered, to name it
    /// on the card if that turns out to be an outside edit.
    func noteSkillFileEdit(_ event: HookEvent, sessionID: UUID) {
        guard let tool = event.toolName, ["Edit", "Write", "MultiEdit"].contains(tool),
              let path = event.toolInput?["file_path"]?.stringValue, path.hasSuffix("/SKILL.md") else { return }
        skillFileEditors[AppModel.resolvedPath(URL(fileURLWithPath: path))] = sessionID
    }

    // MARK: - The cards

    public func outsideEdits(inProject projectID: UUID) -> [OutsideEdit] {
        skillsData(inProject: projectID).outsideEdits
    }

    public func outsideEdit(_ id: UUID, inProject projectID: UUID) -> OutsideEdit? {
        skillsData(inProject: projectID).outsideEdits.first { $0.id == id }
    }

    /// The approved text: the newest history version whose hash is the
    /// record's (nil when history doesn't have it, so Revert can't be offered).
    public func approvedText(of name: String, inProject projectID: UUID) -> String? {
        guard let record = skillsData(inProject: projectID).records.first(where: { $0.name == name && $0.location != .retired })
        else { return nil }
        return skillHistory(name, projectID: projectID).first { SkillText.hash($0.text) == record.contentHash }?.text
    }

    /// The file as it is now (nil when it's gone).
    public func currentText(of edit: OutsideEdit, inProject projectID: UUID) -> String? {
        skillFileURL(edit.name, location: edit.location, projectID: projectID).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// "The Update PR session changed .claude/skills/readme-style/SKILL.md 10h ago".
    public func outsideEditLine(_ edit: OutsideEdit) -> String {
        let file = edit.location == .repository ? AppModel.repositorySkillPath(edit.name) : "\(edit.name)/SKILL.md in Claudio's skills"
        let age = RelativeAge.string(from: edit.foundAt, now: now())
        let when = age == "now" ? "just now" : "\(age) ago"
        let verb = edit.deleted ? "deleted" : "changed"
        if let name = edit.editorName { return "The \(name) session \(verb) \(file) \(when)" }
        return "\(file) was \(verb) \(when)"
    }

    /// What's wrong with the changed text, by the checks a draft must pass
    /// (a secret, a renamed skill, a bad length): Keep Change is refused
    /// while there's anything, so only Revert is offered.
    public func outsideEditProblems(_ edit: OutsideEdit, inProject projectID: UUID) -> [String] {
        guard !edit.deleted, let text = currentText(of: edit, inProject: projectID) else { return [] }
        return skillProblemsNow(text, projectID: projectID, patching: edit.name)
    }

    /// Keep Change: what's in the file now becomes the approved skill's
    /// next version. Checked like a draft first. The file's
    /// `claudio-version` is brought up to match, as one of Claudio's own
    /// writes, and the result is kept in its history.
    @discardableResult
    public func keepOutsideEdit(_ id: UUID, projectID: UUID) -> Bool {
        guard let edit = outsideEdit(id, inProject: projectID), !edit.deleted,
              let current = currentText(of: edit, inProject: projectID) else { return false }
        let problems = skillProblemsNow(current, projectID: projectID, patching: edit.name)
        guard problems.isEmpty else {
            log.append(.error, "Assistant: the change to \(edit.name) wasn't kept: it fails Claudio's checks",
                       detail: problems.map(SecretPatterns.redacted).joined(separator: "\n"))
            showToast("The change doesn't pass Claudio's checks, so it can't be kept. Revert puts back the approved version.")
            return false
        }
        let record = skillsData(inProject: projectID).records.first { $0.name == edit.name && $0.location == edit.location }
        let version = (record?.version ?? 0) + 1
        let text = SkillText.settingMetadata(current, [("claudio-version", String(version))])
        do {
            switch edit.location {
            case .claudio: try assistantStore.writeApprovedSkill(name: edit.name, text: text, projectID: projectID)
            case .repository:
                guard let url = skillFileURL(edit.name, location: .repository, projectID: projectID) else { return false }
                try text.write(to: url, atomically: true, encoding: .utf8)
            case .retired: return false
            }
        } catch {
            report("Couldn't keep the change to \(edit.name): \(AppModel.describe(error))")
            return false
        }
        let hash = SkillText.hash(text)
        do {
            try assistantStore.writeSkillHistory(name: edit.name, version: version, text: text, projectID: projectID)
        } catch {
            log.append(.error, "Couldn't keep version \(version) of \(edit.name) in its history", detail: AppModel.describe(error))
        }
        let date = now()
        forgetSkillFileStamps(edit.name, projectID: projectID)
        updateSkillsData(projectID) { data in
            data.outsideEdits.removeAll { $0.id == id }
            if let index = data.records.firstIndex(where: { $0.name == edit.name && $0.location == edit.location }) {
                data.records[index].contentHash = hash
                data.records[index].version = version
                data.records[index].approvedAt = date
            }
        }
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Kept the change to \(edit.name) (version \(version))")
        showToast("Kept the change to \(edit.name)")
        return true
    }

    /// Revert (or Restore, for one that's gone): writes the approved text
    /// back. Only offered when history holds that text.
    @discardableResult
    public func revertOutsideEdit(_ id: UUID, projectID: UUID) -> Bool {
        guard let edit = outsideEdit(id, inProject: projectID) else { return false }
        guard let text = approvedText(of: edit.name, inProject: projectID) else {
            showToast("Claudio doesn't have the approved text of \(edit.name), so it can't be put back")
            return false
        }
        do {
            switch edit.location {
            case .claudio:
                try assistantStore.writeApprovedSkill(name: edit.name, text: text, projectID: projectID)
            case .repository:
                guard let url = skillFileURL(edit.name, location: .repository, projectID: projectID) else { return false }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            case .retired:
                return false
            }
        } catch {
            report("Couldn't put back \(edit.name): \(AppModel.describe(error))")
            return false
        }
        forgetSkillFileStamps(edit.name, projectID: projectID)
        updateSkillsData(projectID) { $0.outsideEdits.removeAll { $0.id == id } }
        refreshApprovedSkills(projectID: projectID)
        if edit.location == .claudio { syncSkillSets(inProject: projectID) }
        log.append(.info, "\(edit.deleted ? "Restored" : "Reverted") \(edit.name)")
        showToast(edit.deleted ? "Restored \(edit.name)" : "Put back the approved \(edit.name)")
        return true
    }

    /// Keep Deletion: Claudio forgets the skill (its history stays).
    public func keepOutsideDeletion(_ id: UUID, projectID: UUID) {
        guard let edit = outsideEdit(id, inProject: projectID), edit.deleted else { return }
        forgetSkillFileStamps(edit.name, projectID: projectID)
        updateSkillsData(projectID) { data in
            data.outsideEdits.removeAll { $0.id == id }
            data.records.removeAll { $0.name == edit.name && $0.location == edit.location }
        }
        if edit.location == .claudio { skillLeftClaudiosRoot(edit.name, projectID: projectID) }
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Let \(edit.name) go: it was deleted outside Claudio")
    }

    /// Re-links a project's skill sets (after a skill comes back).
    func syncSkillSets(inProject projectID: UUID) {
        for session in workspace.sessions where session.projectID == projectID && session.skillSet != nil { skillSetRoot(of: session) }
    }
}
