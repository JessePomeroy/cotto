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

    func testRejectsMissingShortAnswersEvenBesideLongSurvivingContext() {
        let context = "Keep the existing server running while we review the history and compare the recorded audio against the finished transcript because the whole discussion matters for our implementation and for the next review of the feature."
        for answers in ["A. Agreed. A. Agreed. A. Agreed.", "A\nAgreed\nA\nAgreed\nA\nAgreed"] {
            XCTAssertEqual(TextCorrectionPolicy.rejectionReason(original: answers + "\n" + context, candidate: context), "The rewrite removed an answer or sentence.")
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: answers + "\n" + context, candidate: "A. Agreed. " + context))
        }
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(original: "A. Agreed. A. Agreed. " + context,
            candidate: "A, agreed; A, agreed. " + context))
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: "Keep the audio. " + context, candidate: context))
        let startsWithA = "A detailed implementation plan should preserve the audio and every individual answer during processing and review."
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: "A. " + startsWithA, candidate: startsWithA))
        let endsWithAudio = "We should preserve the original recording for review while processing every individual answer in the audio."
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: endsWithAudio + " Audio.", candidate: endsWithAudio))
    }

    func testAcceptsOnlyAnchoredExplicitSpokenRepairExceptions() {
        for (original, candidate) in [
            ("Orange, err, yellow.", "Yellow."),
            ("I want the color to be orange, er, yellow.", "I want the color to be yellow."),
            ("I want the color to be orange, erm, yellow today.", "I want the color to be yellow today."),
            ("42, sorry, 24.", "24."),
            ("Make it 42, I mean, 24.", "Make it 24."),
            ("Make it 42, correction, 24 before lunch.", "Make it 24 before lunch."),
            ("I cannot merge this, sorry, I can merge this.", "I can merge this."),
            ("I can merge this, I mean, I cannot merge this.", "I cannot merge this."),
            ("We should not ship this, correction, we should ship this tomorrow.", "We should ship this tomorrow."),
        ] {
            let result = TextCorrectionPolicy.evaluate(original: original, candidate: candidate)
            XCTAssertNil(result.rejectionReason, "\(original): \(result.rejectionReason ?? "")")
            XCTAssertEqual(result.verifiedRepairs.count, 1, original)
        }
    }

    func testRepairDoesNotExemptUnrelatedNumbersNegationsOrAnswers() {
        for (original, candidate) in [
            ("Make it 42, err, 24. Keep the other 15 records.", "Make it 24. Keep the other 16 records."),
            ("Make it 42, err, 24. Never merge the result.", "Make it 24. Merge the result."),
            ("Make it 42, err, 24. Agreed. Keep every other word of this lengthy final paragraph because it documents the details for the current decision.", "Make it 24. Keep every other word of this lengthy final paragraph because it documents the details for the current decision."),
            ("5. Apples.\n6. Oranges, err, 7. Pears.", "5. Apples.\n7. Pears."),
        ] {
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate), original)
        }
    }

    func testAlternativesIdentifiersQuotesAndApologiesAreNotRepairCues() {
        for (original, candidate) in [
            ("Orange or yellow.", "Yellow."),
            ("Use the err variable.", "Use the variable."),
            ("Orange, ‘err’, yellow.", "Yellow."),
            ("Orange, `err`, yellow.", "Yellow."),
            ("I am sorry, I cannot merge this.", "I can merge this."),
            ("Orange. Sorry, yellow.", "Yellow."),
        ] {
            let result = TextCorrectionPolicy.evaluate(original: original, candidate: candidate)
            XCTAssertTrue(result.verifiedRepairs.isEmpty, original)
            XCTAssertNotNil(result.rejectionReason, original)
        }
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(original: "I want the color to be orange or yellow.", candidate: "I want the color to be orange or yellow."))
    }

    func testNegationsRemainAttachedToTheirOriginalAction() {
        for (original, candidate) in [
            ("I cannot merge this change before the review.", "I can merge this change before the review."),
            ("There is nothing we should change in this section.", "There is something we should change in this section."),
            ("Do not merge the branch and do deploy the service.", "Do merge the branch and do not deploy the service."),
            ("Nobody should deploy this service before the review.", "Somebody should deploy this service before the review."),
            ("I do not want to merge this change.", "I do want not to merge this change."),
        ] {
            XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: original, candidate: candidate), candidate)
        }
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(original: "I haven’t merged this change.", candidate: "I have not merged this change."))
        XCTAssertNil(TextCorrectionPolicy.rejectionReason(original: "I cannot merge this change.", candidate: "I can’t merge this change."))
    }

    func testModelMayRemoveIsolatedHesitationsWithoutExemptingIdentifiers() {
        for (original, candidate) in [
            ("Um, hello.", "Hello."),
            ("Er, open settings.", "Open settings."),
            ("Please, erm, open settings.", "Please open settings."),
            ("Open settings, uh.", "Open settings."),
        ] {
            let evaluation = TextCorrectionPolicy.evaluate(original: original, candidate: candidate)
            XCTAssertNil(evaluation.rejectionReason, original)
            XCTAssertTrue(evaluation.verifiedRepairs.isEmpty, original)
        }
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: "Print the err variable.", candidate: "Print the variable."))
        XCTAssertNotNil(TextCorrectionPolicy.rejectionReason(original: "Print ‘err’, please.", candidate: "Print, please."))
    }

    func testProcessingDiagnosticsAreBoundedAndOlderRecordsDecode() throws {
        let evaluation = TextCorrectionPolicy.evaluate(original: "42, sorry, 24.", candidate: "24.")
        let record = TextProcessingRecord(dictionaryTerms: [], dictionaryChangedText: false, inputText: "42, sorry, 24.", outputText: "24.", enabled: true, status: .applied, proposedText: String(repeating: "x", count: 13_000), verifiedRepairs: evaluation.verifiedRepairs)
        XCTAssertEqual(record.proposedText?.count, 12_000)
        XCTAssertEqual(record.verifiedRepairs?.first?.abandoned.text, "42")
        XCTAssertEqual(record.verifiedRepairs?.first?.cue.text, "sorry")
        XCTAssertEqual(record.verifiedRepairs?.first?.replacement.text, "24")
        let oldJSON = #"{"dictionaryTerms":[],"dictionaryChangedText":false,"inputText":"hello","outputText":"Hello.","enabled":true,"status":"applied"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TextProcessingRecord.self, from: oldJSON)
        XCTAssertNil(decoded.proposedText)
        XCTAssertNil(decoded.verifiedRepairs)
    }

}
