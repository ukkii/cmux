import CmuxAgentQuestion
@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// The owner's side of a question flow: the question card and its answer.
@Suite struct ChiefCloudFlowTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    static let question = AgentQuestion(
        id: "q-1", source: AgentQuestion.Source(harness: .chief, session: "sess", agentName: "Chief"),
        items: [AgentQuestion.Item(id: "machine", header: "Machine", prompt: "Create a cloud machine?",
                                   options: [AgentQuestion.Option(id: "8g", label: "8 GB", detail: "4 vCPU"),
                                             AgentQuestion.Option(id: "4g", label: "4 GB")],
                                   allowsOther: false)],
        submitLabel: "Create")

    @Test func questionIsPostedAndItsAnswerIsTheNextTurn() async throws {
        let brain = FakeBrain { request, continuation in
            if request.userText == "set up a machine" {
                continuation.yield(.textDelta("Here are the options."))
                continuation.yield(.question(Self.question))
            } else {
                continuation.yield(.textDelta("Creating it."))
                continuation.yield(.textSegmentEnd)
            }
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("set up a machine", to: owner)
        let asked = try await ChiefFixture.idleMessages(owner, count: 3)
        // The text before the card commits as its own bubble, then the card.
        #expect(asked[1].plainText == "Here are the options.")
        guard case .question(let posted) = asked[2].parts.first else {
            Issue.record("expected a question part")
            return
        }
        #expect(posted.isPending && posted.submitLabel == "Create")

        let answer = AgentQuestionAnswer(selections: ["machine": AgentQuestionAnswer.Selection(optionIDs: ["4g"])])
        _ = try await owner.submit(HomeIntent(op: .answerQuestion(message: asked[2].id, conversation: conversation,
                                                                   partIndex: 0, answer: answer)))
        let after = try await ChiefFixture.idleMessages(owner, count: 4)
        guard case .question(let answered) = after[2].parts.first, case .answered(let stored) = answered.state else {
            Issue.record("expected the answered question")
            return
        }
        #expect(stored.selections["machine"]?.optionIDs == ["4g"])
        #expect(answered.submitLabel == "Create")
        #expect(after.last?.plainText == "Creating it.")
        let requests = await brain.log.requests
        #expect(requests.count == 2)
        #expect(requests.last?.userText.contains("Machine: 4 GB") == true)

        // A second answer is refused: the card is closed.
        await #expect(throws: HomeRejection.invalid("question_closed")) {
            _ = try await owner.submit(HomeIntent(op: .answerQuestion(message: asked[2].id, conversation: self.conversation,
                                                                       partIndex: 0, answer: answer)))
        }
    }
}
