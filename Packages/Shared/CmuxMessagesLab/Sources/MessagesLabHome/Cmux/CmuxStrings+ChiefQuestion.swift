import Foundation

/// The Chief's question card (Resources/CmuxHome.xcstrings).
extension CmuxStrings {
    /// VoiceOver's name for the question card.
    static var questionRole: String {
        String(localized: "home.question.role", defaultValue: "Question", table: "CmuxHome", bundle: .module)
    }
    /// The card's primary button when the Chief named none.
    static var questionSubmit: String {
        String(localized: "home.question.submit", defaultValue: "Submit", table: "CmuxHome", bundle: .module)
    }
    /// A Chief question card the user answered by writing instead (the receipt row).
    static var questionAnsweredInChat: String {
        String(localized: "home.question.answeredInChat", defaultValue: "Answered in chat", table: "CmuxHome", bundle: .module)
    }
    static var questionCancelled: String {
        String(localized: "home.question.cancelled", defaultValue: "Cancelled", table: "CmuxHome", bundle: .module)
    }
}
