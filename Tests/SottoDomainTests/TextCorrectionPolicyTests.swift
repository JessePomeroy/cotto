import Foundation
import XCTest
@testable import SottoDomain

final class TextCorrectionPolicyTests: XCTestCase {
    func testAcceptsConservativeSpellingCasingAndPunctuationCorrections() {
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(
            original: "please open codecks and minimax settings for this project",
            candidate: "Please open Codex and MiniMax settings for this project."))
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(
            original: "Open codeks now.", candidate: "Open Codex now.", preferredTerms: ["Codex"]))
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(
            original: "Open codeks now.", candidate: "Open Codex now."))
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(
            original: "I don't think we should ship this yet",
            candidate: "I don’t think we should ship this yet."))
    }

    func testAcceptsParagraphBreaksWithoutChangingListStructureOrQuantities() {
        let original = "Here is the plan. First we test the microphone.\n3. Order 2 new cables.\n4. Spend $20.50 on adapters.\n7. Leave at 10:30."
        let candidate = "Here is the plan.\n\nFirst, we test the microphone.\n\n  3. Order 2 new cables.\n  4. Spend $20.50 on adapters.\n  7. Leave at 10:30."
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate))
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(original: "- buy apples\n- buy oranges", candidate: "- Buy apples.\n- Buy oranges."))
    }

    func testRejectsEmptyControlTokenAndOversizedOutputs() {
        let original = "Please open the microphone settings."
        for candidate in ["", " \n ", "<|im_start|>Please open the microphone settings.", "<think>check</think> Please open the microphone settings.", String(repeating: "a", count: TextCorrectionPolicy.maximumInputCharacters * 2 + 1)] {
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate))
        }
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: "...", candidate: "Something new."))
    }

    func testRejectsChangedNumbersSignsCurrenciesPercentagesAndWrittenQuantities() {
        for (original, candidate) in [
            ("Please order 25 microphones for the project.", "Please order 26 microphones for the project."),
            ("Please arrive at 10:30 for the meeting.", "Please arrive at 10:00 for the meeting."),
            ("The total for this purchase is $20.", "The total for this purchase is €20."),
            ("Set the temperature to -20 degrees now.", "Set the temperature to 20 degrees now."),
            ("Set the progress indicator to 20% now.", "Set the progress indicator to 20 now."),
            ("We need two microphones for the project.", "We need three microphones for the project."),
            ("Order ٢ new microphones for the project.", "Order ٣ new microphones for the project."),
        ] {
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate), "Accepted changed quantity: \(candidate)")
        }
    }

    func testRejectsRenumberedRemovedMergedOrRestyledListItems() {
        let original = "3. Order apples.\n4. Order oranges.\n7. Order syrup."
        for candidate in [
            "1. Order apples.\n2. Order oranges.\n3. Order syrup.",
            "3. Order apples.\n4. Order oranges and syrup.",
            "3. Order apples. 4. Order oranges. 7. Order syrup.",
            "- Order apples.\n- Order oranges.\n- Order syrup.",
        ] {
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate))
        }
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: "- Order apples.\n- Order oranges.", candidate: "• Order apples.\n• Order oranges."))
    }

    func testRejectsAnswersPreamblesAndSubstantialRemoval() {
        let original = "Please explain how to configure this new local service on my Mac and how to keep it running when I close the window."
        for candidate in [
            "Open Settings, enable the service, and turn on background access.",
            "Please explain how to configure this service.",
            "Here is the corrected text: \(original)",
        ] {
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate), "Accepted non-transcript output: \(candidate)")
        }
    }

    func testRejectsAddedRemovedOrChangedNegations() {
        for (original, candidate) in [
            ("Please do not delete the archived audio recordings.", "Please do delete the archived audio recordings."),
            ("Please delete the archived audio recordings after review.", "Please never delete the archived audio recordings after review."),
            ("We should work without uploading the recordings anywhere.", "We should work with uploading the recordings anywhere."),
            ("I don't think the service should run today.", "I think the service should run today."),
        ] {
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate))
        }
    }

    func testRejectsReorderedContentAndListBodiesEvenWhenAllWordsRemain() {
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(
            original: "Please start the local service before deleting the old recordings.",
            candidate: "Before deleting the local service please start the old recordings."))
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(
            original: "1. Start the local service.\n2. Delete the old recordings.",
            candidate: "1. Delete the old recordings.\n2. Start the local service."))
    }

    func testModelHintLimitsKeepWholeTermsAndDoNotLimitDictionaryCorrections() {
        let terms = (0..<90).map { "Tool\($0)" }
        XCTAssertEqual(TextCorrectionPolicy.modelHints(terms), Array(terms.prefix(80)))
        let dictionary = PersonalDictionary(lists: [DictionaryList(id: "tools", name: "Tools", entries:
            terms.enumerated().map { DictionaryEntry(id: "\($0.offset)", term: $0.element) })])
        XCTAssertEqual(dictionary.apply(to: "Open tool0 and tool89."), "Open Tool0 and Tool89.")

        let oversized = String(repeating: "語", count: 86) // 258 UTF-8 bytes, 86 characters.
        XCTAssertEqual(TextCorrectionPolicy.modelHints([oversized, "Codex"]), ["Codex"])
        let longWord = PersonalDictionary(lists: [DictionaryList(id: "long", name: "Long", entries: [
            DictionaryEntry(id: "long-word", term: oversized, aliases: ["long product name"]),
        ])])
        XCTAssertEqual(longWord.apply(to: "Use long product name."), "Use \(oversized).")

        let fillsByteBudget = (0..<64).map { String(format: "%02d", $0) + String(repeating: "a", count: 62) }
        XCTAssertEqual(TextCorrectionPolicy.modelHints(fillsByteBudget + ["Codex"]), fillsByteBudget)
        XCTAssertEqual(TextCorrectionPolicy.modelHints([String(repeating: "é", count: 128)]).first?.utf8.count, 256)
    }

    func testExistingPreferredTermOccurrencesSurviveProofreading() {
        let original = "Please open MiniMax and compare the local model settings with MiniMax again."
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(original: original,
            candidate: "Please open MiniMax, and compare the local model settings with MiniMax again.", preferredTerms: ["MiniMax"]))
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original,
            candidate: "Please open OpenAI and compare the local model settings with MiniMax again.", preferredTerms: ["MiniMax"]))
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: "Please open Codex, and then close the settings window.",
            candidate: "Please open Codex and Codex, and then close the settings window.", preferredTerms: ["Codex"]))
    }

}
