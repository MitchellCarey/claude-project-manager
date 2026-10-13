import Foundation

// Step 5b of the Project Assistant: retiring skills nobody uses. Once a
// day, in code (no Claude call), each of Claudio's own approved skills that
// no session has used for 30 days becomes a Needs You card, Retire or Keep,
// while the assistant is on. Approving counts as a use, so a new skill
// isn't unused from day one. Repository skills never get one: Claudio can't
// see them used outside it, and retiring one would move your file.

extension AppModel {
    /// Days without a use before a skill is offered for retiring.
    public static let unusedSkillDays = 30

    /// The once-a-day check (from the 15 s tick).
    func checkUnusedSkills() {
        let today = DailyJobCount.day(of: now())
        guard unusedSkillCheckDay != today else { return }
        unusedSkillCheckDay = today
        for project in workspace.projects where isAssistantOn(inProject: project.id) && !unreadableSkillsData.contains(project.id) {
            findUnusedSkills(projectID: project.id)
        }
    }

    /// Cards for Claudio's skills last used `unusedSkillDays` ago or more:
    /// by their last use, else their approval. One with neither (put there
    /// by hand) is given today as a start, with no card.
    func findUnusedSkills(projectID: UUID) {
        let data = skillsData(inProject: projectID)
        let date = now()
        let cutoff = date.addingTimeInterval(-Double(AppModel.unusedSkillDays) * 86_400)
        var found: [UnusedSkill] = []
        var starts: [String] = []
        for skill in approvedSkills[projectID] ?? [] where !data.unusedSkills.contains(where: { $0.name == skill.name }) {
            let record = data.records.first { $0.name == skill.name && $0.location == .claudio }
            guard let last = data.usage[skill.name]?.lastUsed ?? record?.approvedAt else {
                starts.append(skill.name)
                continue
            }
            if last <= cutoff { found.append(UnusedSkill(name: skill.name, lastUsed: last, foundAt: date)) }
        }
        guard !found.isEmpty || !starts.isEmpty else { return }
        updateSkillsData(projectID) { data in
            data.unusedSkills += found
            for name in starts { data.usage[name, default: SkillUsage()].lastUsed = date }
        }
        if !found.isEmpty {
            log.append(.info, "\(found.count) skill\(found.count == 1 ? "" : "s") unused for \(AppModel.unusedSkillDays) days",
                       detail: found.map(\.name).joined(separator: ", "))
        }
    }

    public func unusedSkills(inProject projectID: UUID) -> [UnusedSkill] {
        skillsData(inProject: projectID).unusedSkills
    }

    public func unusedSkill(_ id: UUID, inProject projectID: UUID) -> UnusedSkill? {
        skillsData(inProject: projectID).unusedSkills.first { $0.id == id }
    }

    /// Keep: counts as a use, so it isn't asked about for another 30 days.
    public func keepUnusedSkill(_ id: UUID, projectID: UUID) {
        guard let unused = unusedSkill(id, inProject: projectID) else { return }
        let date = now()
        updateSkillsData(projectID) { data in
            data.unusedSkills.removeAll { $0.id == id }
            data.usage[unused.name, default: SkillUsage()].lastUsed = date
        }
    }

    /// Retire: moves the skill out of Claudio's root, so no session loads
    /// it (a running one stops seeing it within seconds), and out of every
    /// skill set. Restore, from Skills, brings it back.
    @discardableResult
    public func retireSkill(_ name: String, projectID: UUID) -> Bool {
        guard (approvedSkills[projectID] ?? []).contains(where: { $0.name == name }) else { return false }
        do {
            try assistantStore.retireSkill(name: name, projectID: projectID)
        } catch {
            report("Couldn't retire \(name): \(AppModel.describe(error))")
            return false
        }
        forgetSkillFileStamps(name, projectID: projectID)
        updateSkillsData(projectID) { data in
            data.unusedSkills.removeAll { $0.name == name }
            data.outsideEdits.removeAll { $0.name == name && $0.location == .claudio }
            if let index = data.records.firstIndex(where: { $0.name == name && $0.location == .claudio }) {
                data.records[index].location = .retired
            }
        }
        skillLeftClaudiosRoot(name, projectID: projectID)
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Retired the skill \(name)")
        showToast("Retired \(name). Restore it from Skills.")
        return true
    }

    /// Retire on an Unused Skill card.
    @discardableResult
    public func retireUnusedSkill(_ id: UUID, projectID: UUID) -> Bool {
        guard let unused = unusedSkill(id, inProject: projectID) else { return false }
        return retireSkill(unused.name, projectID: projectID)
    }

    /// Restore: back into Claudio's root, where every shared-skills session
    /// loads it again. Counts as a use. Refused when a skill of that name
    /// has been approved since.
    @discardableResult
    public func restoreSkill(_ name: String, projectID: UUID) -> Bool {
        guard (retiredSkills[projectID] ?? []).contains(where: { $0.name == name }) else { return false }
        guard !existingSkillNames(projectID: projectID).contains(name) else {
            showToast("A skill called \(name) exists now, so this one can't be restored")
            return false
        }
        do {
            try assistantStore.restoreSkill(name: name, projectID: projectID)
        } catch {
            report("Couldn't restore \(name): \(AppModel.describe(error))")
            return false
        }
        forgetSkillFileStamps(name, projectID: projectID)
        let date = now()
        updateSkillsData(projectID) { data in
            if let index = data.records.firstIndex(where: { $0.name == name && $0.location == .retired }) {
                data.records[index].location = .claudio
            }
            data.usage[name, default: SkillUsage()].lastUsed = date
        }
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Restored the skill \(name)")
        showToast("Restored \(name)")
        return true
    }
}
