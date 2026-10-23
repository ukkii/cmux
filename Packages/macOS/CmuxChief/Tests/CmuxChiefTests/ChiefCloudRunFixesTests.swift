import CmuxAgentQuestion
@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// What the real Cloud run (chief-dogfood-1) got wrong on the owner's side: a question card
/// answered by typing stayed live, every `vm exec` probe asked with no Always Allow, a sign-in
/// screen read as a failure, and the prompt pushed a 17 GB checkout.
@Suite struct ChiefCloudRunFixesTests {
    let conversation = ChiefConversationOwner.defaultConversationID
    typealias FollowUp = ChiefCloudFollowUpTests

    // MARK: Typed answers

    @Test func chatTextAnswersACardOnlyWhenItNamesEveryItem() throws {
        let one = FollowUp.question([FollowUp.machine])
        for text in ["4 GB", "4 gb.", "Machine: 4 GB", "My answer to your question:\nMachine: 4 GB", "  4g!"] {
            let answer = try #require(ChiefQuestionAnswer.fromChat(text, question: one), "\(text)")
            #expect(answer.selections["machine"]?.optionIDs == ["4g"], "\(text)")
        }
        #expect(ChiefQuestionAnswer.fromChat("8 GB please", question: one) == nil)
        #expect(ChiefQuestionAnswer.fromChat("actually, use the existing machine", question: one) == nil)
        // Two items: naming one is not an answer (no silent preselection from chat).
        let two = FollowUp.question([FollowUp.machine, FollowUp.name])
        #expect(ChiefQuestionAnswer.fromChat("8 GB", question: two) == nil)
        let both = try #require(ChiefQuestionAnswer.fromChat("8 GB\nweb", question: two))
        #expect(both.selections["machine"]?.optionIDs == ["8g"])
        #expect(both.selections["name"]?.optionIDs == ["web"])
    }

    private func cardOwner() async throws -> (ChiefConversationOwner, FakeBrain, ChiefConversationOwner.PendingQuestion) {
        let card = FollowUp.question([FollowUp.machine])
        let brain = FakeBrain { request, continuation in
            if request.userText == "set up a machine" { continuation.yield(.question(card)) }
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("set up a machine", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        let pending = try #require(await owner.pendingQuestion(in: conversation))
        return (owner, brain, pending)
    }

    private func storedQuestion(_ owner: ChiefConversationOwner, _ message: MessageID) async throws -> AgentQuestion? {
        let messages = try await owner.snapshot(of: conversation, tail: 20).messages
        guard case .question(let question)? = messages.first(where: { $0.id == message })?.parts.first else { return nil }
        return question
    }

    @Test func aTypedChoiceAnswersTheCardAndTheChiefHearsTheMessage() async throws {
        let (owner, brain, pending) = try await cardOwner()
        try await ChiefFixture.send("8 GB", to: owner)
        let stored = try #require(try await storedQuestion(owner, pending.message))
        guard case .answered(let answer) = stored.state else { Issue.record("the card still waits"); return }
        #expect(answer.selections["machine"]?.optionIDs == ["8g"])
        #expect(stored.summaryLines(answer) == ["Machine: 8 GB"])
        #expect(await owner.pendingQuestion(in: conversation) == nil)
        // One turn for the typed message, with the user's own words.
        #expect(await ChiefFixture.eventually { await brain.log.requests.count == 2 })
        #expect(await brain.log.requests.last?.userText == "8 GB")
    }

    @Test func otherTypedTextClosesTheCardAsAnsweredInChat() async throws {
        let (owner, _, pending) = try await cardOwner()
        try await ChiefFixture.send("Use my existing machine instead", to: owner)
        let stored = try #require(try await storedQuestion(owner, pending.message))
        #expect(stored.state == .cancelled)
        #expect(await owner.pendingQuestion(in: conversation) == nil)
    }

    // MARK: No Always Allow for vm exec

    /// This fork has no cmux Cloud, so `cmux vm|cloud exec` never gets an Always Allow rule,
    /// and a rule for it stored on disk by an older build is not honored.
    @Test func vmExecGetsNoAlwaysAllowRule() throws {
        for command in [
            "cmux vm exec chief-dogfood-1 -- pwd", "cmux vm exec --timeout 600 vm-794a -- git clone https://x/y work/y",
            "cmux cloud exec vm-794a -- id", "cmux vm rm vm-794a",
        ] {
            #expect(ChiefAllowRules.prefix(for: command) == nil, "\(command)")
        }
        #expect(ChiefToolPolicy.approvalOptions(command: "cmux vm exec vm-794a -- pwd") == ["Allow", "Deny"])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root)
        try FileManager.default.createDirectory(at: home.stateDirectory, withIntermediateDirectories: true)
        try Data(#"{"rules":[["cmux","vm","exec","vm-794a"]]}"#.utf8)
            .write(to: home.stateDirectory.appendingPathComponent("allow-rules.json"))
        let reader = ChiefAllowRules()
        reader.load(home)
        #expect(reader.all.isEmpty)
        #expect(!reader.allows(["cmux", "vm", "exec", "vm-794a", "--", "pwd"]))
    }

    // MARK: Prompt

    @Test func thePromptTeachesNoCloudMachines() {
        for prompt in [
            ChiefSystemPrompt(context: ChiefPromptContext()).build(),
            ChiefSystemPrompt(context: ChiefPromptContext(dangerouslySkipPermissions: true)).build(),
        ] {
            for rule in ["cmux vm", "/home/cmux", "cmux ai-accounts upload", "cmux Pro", "cmux-result"] {
                #expect(!prompt.contains(rule), "unexpected \(rule)")
            }
        }
    }
}
