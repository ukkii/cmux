import CmuxAgentQuestion
@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// Gaps a real run found: question cards answered without Home (`chief.answer`) and a
/// denied command that leaves only its approval receipt.
@Suite struct ChiefCloudFollowUpTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    // MARK: Answers from words

    static let machine = AgentQuestion.Item(
        id: "machine", header: "Machine", prompt: "Create a cloud machine?",
        options: [AgentQuestion.Option(id: "4g", label: "4 GB"), AgentQuestion.Option(id: "8g", label: "8 GB")],
        allowsOther: false)
    static let tools = AgentQuestion.Item(
        id: "tools", header: "Tools", prompt: "Install?",
        options: [AgentQuestion.Option(id: "node", label: "Node"), AgentQuestion.Option(id: "rust", label: "Rust")],
        multiSelect: true)
    static let name = AgentQuestion.Item(
        id: "name", header: "Name", prompt: "Name it?",
        options: [AgentQuestion.Option(id: "api", label: "api"), AgentQuestion.Option(id: "web", label: "web")])

    static func question(_ items: [AgentQuestion.Item]) -> AgentQuestion {
        AgentQuestion(id: "q-1", source: AgentQuestion.Source(harness: .chief, session: "sess", agentName: "Chief"),
                      items: items, submitLabel: "Create")
    }

    @Test func choicesNameOptionsByLabelOrIDAndUnnamedItemsKeepThePreselection() throws {
        let card = Self.question([Self.machine, Self.name])
        // By label, case-insensitive; the unnamed item keeps its first option (the card's preselection).
        let byLabel = try ChiefQuestionAnswer(choices: ["8 gb"], text: nil).answer(for: card)
        #expect(byLabel.selections["machine"]?.optionIDs == ["8g"])
        #expect(byLabel.selections["name"]?.optionIDs == ["api"])
        // By id; nothing named is Submit right away.
        #expect(try ChiefQuestionAnswer(choices: ["web"], text: nil).answer(for: card).selections["name"]?.optionIDs == ["web"])
        let defaults = try ChiefQuestionAnswer(choices: [], text: nil).answer(for: card)
        #expect(defaults.selections["machine"]?.optionIDs == ["4g"] && defaults.selections["name"]?.optionIDs == ["api"])
        #expect(throws: ChiefQuestionAnswer.Problem.unknownChoice("32 GB")) {
            try ChiefQuestionAnswer(choices: ["32 GB"], text: nil).answer(for: card)
        }
        // Two options of one single-choice item contradict the card.
        #expect(throws: ChiefQuestionAnswer.Problem.self) {
            try ChiefQuestionAnswer(choices: ["4 GB", "8 GB"], text: nil).answer(for: Self.question([Self.machine]))
        }
    }

    @Test func qualifiedChoicesStayWithTheirQuestionWhenOptionIDsRepeat() throws {
        let first = AgentQuestion.Item(
            id: "first", prompt: "First?",
            options: [AgentQuestion.Option(id: "yes", label: "No")])
        let second = AgentQuestion.Item(
            id: "second", prompt: "Second?",
            options: [AgentQuestion.Option(id: "yes", label: "Yes")])
        let card = Self.question([first, second])
        let separator = ChiefQuestionAnswer.qualifiedChoiceSeparator
        let answer = try ChiefQuestionAnswer(choices: ["second\(separator)yes"], text: nil).answer(for: card)
        #expect(answer.selections["first"]?.optionIDs == ["yes"])
        #expect(answer.selections["second"]?.optionIDs == ["yes"])
    }

    @Test func textFillsTheFirstItemThatTakesItAndMultiChoiceItemsNeedAChoice() throws {
        // "Machine" takes no Other text, so the text goes to "Name".
        let typed = try ChiefQuestionAnswer(choices: [], text: "billing").answer(for: Self.question([Self.machine, Self.name]))
        #expect(typed.selections["name"] == AgentQuestionAnswer.Selection(optionIDs: [], other: "billing"))
        #expect(typed.selections["machine"]?.optionIDs == ["4g"])
        #expect(throws: ChiefQuestionAnswer.Problem.otherNotAllowed) {
            try ChiefQuestionAnswer(choices: [], text: "huge").answer(for: Self.question([Self.machine]))
        }
        // A multi-choice item has no preselection: it needs a choice.
        let multi = Self.question([Self.tools])
        #expect(try ChiefQuestionAnswer(choices: ["Node", "rust"], text: nil).answer(for: multi).selections["tools"]?.optionIDs
            == ["node", "rust"])
        #expect(throws: ChiefQuestionAnswer.Problem.self) { try ChiefQuestionAnswer(choices: [], text: nil).answer(for: multi) }
    }

    @Test func answeringAQuestionCardClosesItAndStartsTheNextTurn() async throws {
        let card = Self.question([Self.machine])
        let brain = FakeBrain { request, continuation in
            if request.userText == "set up a machine" { continuation.yield(.question(card)) }
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("set up a machine", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        let pending = try #require(await owner.pendingQuestion(in: conversation))
        #expect(pending.part == 0 && pending.question.isPending)
        #expect(await owner.pendingQuestion(in: conversation, message: "msg_other") == nil)
        #expect(await owner.pendingQuestion(in: conversation, message: pending.message.rawValue) == pending)

        let lines = try await owner.answerQuestion(pending, in: conversation, choices: ["8 GB"], text: nil)
        #expect(lines == ["Machine: 8 GB"])
        // The card records it (the same HomeOp.answerQuestion as its button) and no longer waits.
        let messages = try await owner.snapshot(of: conversation, tail: 10).messages
        guard case .question(let answered)? = messages.first(where: { $0.id == pending.message })?.parts.first,
              case .answered(let stored) = answered.state else { Issue.record("expected the answered card"); return }
        #expect(stored.selections["machine"]?.optionIDs == ["8g"])
        #expect(await owner.pendingQuestion(in: conversation) == nil)
        #expect(await ChiefFixture.eventually { await brain.log.requests.count == 2 })
        #expect(await brain.log.requests.last?.userText.contains("Machine: 8 GB") == true)
        await #expect(throws: HomeRejection.invalid("question_closed")) {
            try await owner.answerQuestion(pending, in: self.conversation, choices: [], text: nil)
        }
    }

    // MARK: Approval of a create command

    static let create = "cmux vm new --detach --name api --size 8g --json"

    /// A brain that starts `vm new`, asks to run it, waits at `gate`, then finishes it with `output`.
    static func creatingBrain(_ gate: Gate, ok: Bool = true, output: String) -> FakeBrain {
        FakeBrain { _, continuation in
            continuation.yield(.toolStarted(id: "t1", title: "Bash", detail: create))
            continuation.yield(.approvalRequested(id: "perm-1", prompt: "Run `\(create)`?", options: ["Allow", "Deny"]))
            await gate.wait()
            continuation.yield(.toolFinished(id: "t1", ok: ok, preview: output))
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    @Test func aDeniedCreateLeavesOnlyTheReceipt() async throws {
        let gate = Gate()
        let owner = try ChiefFixture().owner(Self.creatingBrain(gate, ok: false, output: "denied"))
        try await ChiefFixture.send("create it", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWaitingForApproval(conversation) })
        let card = try #require(await owner.pendingApproval(in: conversation))
        try await owner.answerApproval(conversation: conversation, message: card.message, part: card.part, choice: "Deny")
        await gate.open()
        let messages = try await ChiefFixture.idleMessages(owner, count: 2)
        #expect(messages.count == 2)
        guard case .approval(let ref)? = messages.last?.parts.first else { Issue.record("expected the receipt"); return }
        #expect(ref.decided == "Deny")
    }
}
