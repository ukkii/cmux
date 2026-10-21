import AppKit
import CmuxAgentQuestion
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Rows a real run got wrong: an answered question card stayed live with "Create", and a
/// command that failed after Allow still read as a green "Allowed".
@MainActor @Suite struct ChiefRunRowsTests {
    typealias Rows = ChiefRowsTests

    static let machine = AgentQuestion.Item(
        id: "machine", header: "Machine", prompt: "Which machine size?",
        options: [AgentQuestion.Option(id: "4g", label: "4 GB"), AgentQuestion.Option(id: "8g", label: "8 GB")],
        allowsOther: false)

    static func question(_ state: AgentQuestion.State = .pending) -> AgentQuestion {
        AgentQuestion(id: "q-1", source: AgentQuestion.Source(harness: .chief, session: "sess", agentName: "Chief"),
                      items: [machine], state: state, submitLabel: "Create")
    }

    // MARK: Question receipt

    @Test func anAnsweredCardCollapsesToOneReceiptRow() {
        let answer = AgentQuestionAnswer(selections: ["machine": AgentQuestionAnswer.Selection(optionIDs: ["4g"])])
        let answered = Self.question(.answered(answer))
        #expect(QuestionCardRow.receipt(answered) == "Machine: 4 GB")
        let provider = QuestionCardRowProvider.shared
        let part = QuestionCardRow.part(answered)
        #expect(provider.layout(for: part) == .fullWidth)
        let size = provider.measure(part, maxWidth: 500)
        #expect(size.width == 500)
        #expect(size.height == QuestionCardRow.receiptHeight)
        // Still waiting: the card with its chips and Create.
        let pending = QuestionCardRow.part(Self.question())
        #expect(provider.layout(for: pending) == .bubbleIncoming)
        #expect(provider.measure(pending, maxWidth: 500).height > QuestionCardRow.receiptHeight + 20)
        #expect(QuestionCardRow.receipt(Self.question()) == nil)
    }

    @Test func aCardClosedByATypedReplySaysSoAndAnotherHarnessSaysCancelled() {
        #expect(QuestionCardRow.receipt(Self.question(.cancelled)) == CmuxStrings.questionAnsweredInChat)
        var claude = Self.question(.cancelled)
        claude.source = AgentQuestion.Source(harness: .claude, session: "sess")
        #expect(QuestionCardRow.receipt(claude) == CmuxStrings.questionCancelled)
    }

    // MARK: Allowed, then failed

    /// Claude Code titles a Bash call with its description; the card quotes the command. The
    /// receipt still folds into the row, and a failure shows as the failure, not "Allowed".
    @Test func anAllowedCallFoldsByItsCommandAndItsFailureWins() {
        let command = "git clone --depth 1 https://github.com/manaflow-ai/cmux work/readme-title"
        let approval = MessagePart.approval(ApprovalRef(request: "perm-1", prompt: "Run `\(command)`?",
                                                        options: ["Allow", "Deny"], decided: "Allow"))
        func row(_ status: WorkRef.Status) -> MessagePart {
            .work(WorkRef(session: "t1", title: "Clone the repo", status: status, preview: command))
        }
        let running = [Rows.item(1, [approval]), Rows.item(2, [row(.running)])]
        guard case let .head(calls, allowed)? = ChiefRows.roles(running).value(for: IdempotencyKey("k1")) else {
            Issue.record("the receipt did not fold into the run")
            return
        }
        #expect(allowed && calls.map(\.id) == ["t1"])
        #expect(ChiefRows.roles(running).value(for: IdempotencyKey("k2")) == .folded)

        let failed = [Rows.item(1, [approval]), Rows.item(2, [row(.failed)])]
        guard case let .head(_, failedAllowed)? = ChiefRows.roles(failed).value(for: IdempotencyKey("k1")) else {
            Issue.record("the receipt did not fold into the failed run")
            return
        }
        #expect(!failedAllowed)
        let tools = Rows.tools(Rows.message(failed[0], in: failed).parts.first)
        #expect(tools?.allowed == nil)
        #expect(tools?.state == .failed)
    }
}
