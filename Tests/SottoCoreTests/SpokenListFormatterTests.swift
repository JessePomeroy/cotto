import XCTest
@testable import SottoCore

final class SpokenListFormatterTests: XCTestCase {
    func testActualScreenshotDictationDropsOnlyResumeChatterAndPreservesNumbers() {
        let input = "Sorry, I wanted that screenshot. Go ahead. My voice to text was just ruined. Let me go back to where I was with that list. Three, oranges. Four, a trip to the beach. Seven, more syrup. That's the end of the list."
        let result = SpokenListFormatter.format(input)
        XCTAssertEqual(result.text, "3. oranges\n4. a trip to the beach\n7. more syrup")
        XCTAssertNil(result.context)
        XCTAssertTrue(result.containsList)
        XCTAssertTrue(result.endedList)
        XCTAssertFalse(result.continuesPreviousList)
    }

    func testNumberedListContinuesAcrossHoldsAndExplicitNumbersWin() {
        let first = SpokenListFormatter.format("Make a list. One, apples. Two, bananas.")
        XCTAssertEqual(first.text, "1. apples\n2. bananas")
        XCTAssertEqual(first.context, SpokenListContext(style: .numbered, nextNumber: 3))

        let next = SpokenListFormatter.format("Next item, oranges.", context: first.context)
        XCTAssertEqual(next.text, "3. oranges")
        XCTAssertTrue(next.continuesPreviousList)

        let resumed = SpokenListFormatter.format("Continue the list. Number four, a trip to the beach. Item seven, more syrup.", context: next.context)
        XCTAssertEqual(resumed.text, "4. a trip to the beach\n7. more syrup")
        XCTAssertEqual(resumed.context?.nextNumber, 8)
        XCTAssertTrue(resumed.continuesPreviousList)

        let implicit = SpokenListFormatter.format("Maple syrup.", context: resumed.context)
        XCTAssertEqual(implicit.text, "8. Maple syrup")
    }

    func testResumeWithExistingContextDoesNotConsumeAnItemForChatter() {
        let context = SpokenListContext(style: .numbered, nextNumber: 3)
        let result = SpokenListFormatter.format("Sorry, I wanted that screenshot. Go ahead. My voice to text was just ruined. Let me go back to where I was with that list. Next item, oranges.", context: context)
        XCTAssertEqual(result.text, "3. oranges")
        XCTAssertEqual(result.context?.nextNumber, 4)
        XCTAssertTrue(result.continuesPreviousList)
    }

    func testEndThenOrdinaryProseAndLaterHold() {
        let result = SpokenListFormatter.format("Three, oranges. End of list. Please send the receipt tomorrow.", context: SpokenListContext(style: .numbered, nextNumber: 3))
        XCTAssertEqual(result.text, "3. oranges\n\nPlease send the receipt tomorrow.")
        XCTAssertNil(result.context)
        XCTAssertTrue(result.endedList)
        let next = SpokenListFormatter.format("I bought three oranges.", context: result.context)
        XCTAssertEqual(next.text, "I bought three oranges.")
        XCTAssertFalse(next.containsList)
    }

    func testBulletsAndBulletContinuation() {
        let first = SpokenListFormatter.format("Start a bulleted list. Bullet point, apples. Next bullet, bananas.")
        XCTAssertEqual(first.text, "- apples\n- bananas")
        XCTAssertEqual(first.context?.style, .bulleted)
        let next = SpokenListFormatter.format("Continue the list. Next item, oranges.", context: first.context)
        XCTAssertEqual(next.text, "- oranges")
        XCTAssertTrue(next.continuesPreviousList)
        let end = SpokenListFormatter.format("That's the end of the list.", context: next.context)
        XCTAssertEqual(end.text, "")
        XCTAssertTrue(end.isControlOnly)
        XCTAssertTrue(end.endedList)
        XCTAssertNil(end.context)
    }

    func testControlOnlyStartsAndExplicitNewLists() {
        let start = SpokenListFormatter.format("Start a numbered list.")
        XCTAssertEqual(start.text, "")
        XCTAssertTrue(start.isControlOnly)
        XCTAssertFalse(start.containsList)
        XCTAssertEqual(start.context?.nextNumber, 1)
        let next = SpokenListFormatter.format("Next item.", context: start.context)
        XCTAssertTrue(next.isControlOnly)
        XCTAssertEqual(next.context?.nextNumber, 1)
        let new = SpokenListFormatter.format("Start a new list. One, pears.", context: SpokenListContext(style: .numbered, nextNumber: 8))
        XCTAssertEqual(new.text, "1. pears")
        XCTAssertFalse(new.continuesPreviousList)
    }

    func testControlOnlyResumeAndNextKeepExistingContinuation() {
        let context = SpokenListContext(style: .numbered, nextNumber: 3)
        for command in ["Resume the list.", "Continue this list", "Next item.", "Let me go back to the list."] {
            let result = SpokenListFormatter.format(command, context: context)
            XCTAssertTrue(result.isControlOnly, command)
            XCTAssertTrue(result.continuesPreviousList, command)
            XCTAssertEqual(result.context, context, command)
            XCTAssertFalse(result.endsWithList, command)
        }
        let restart = SpokenListFormatter.format("End list. Start a new list.", context: context)
        XCTAssertTrue(restart.isControlOnly)
        XCTAssertFalse(restart.continuesPreviousList)
        XCTAssertEqual(restart.context?.nextNumber, 1)
    }

    func testSilenceDoesNotEndOrAdvanceContext() {
        let context = SpokenListContext(style: .numbered, nextNumber: 4)
        for input in ["", "  ", "\n\n"] {
            let result = SpokenListFormatter.format(input, context: context)
            XCTAssertEqual(result.text, "")
            XCTAssertEqual(result.context, context)
            XCTAssertFalse(result.isControlOnly)
            XCTAssertFalse(result.endedList)
        }
    }

    func testOrdinaryLanguageAndQuantitiesRemainUntouchedWithoutListIntent() {
        let examples = [
            "I bought three oranges.", "Call at four.", "One thing matters.",
            "First we test. Second we ship.", "First we test.\n\nSecond we ship.",
            "We need 3.5 litres and $12.50 for lunch.", "Meet at 4:30 on 2026-09-03.",
            "Use 1/2 cup of sugar and 3/4 cup of flour.", "One, two, three.",
            "2026. Revenue increased. 2027. We expect growth.",
            "The end of the list is missing.", "Make a list of my expenses for tomorrow.",
            "Sorry, I wanted that screenshot. My voice to text was just ruined.",
            "Item 123 is missing.", "Number one is our priority.", "New item added to the cart.",
            "Bullet point formatting is broken.", "Next item arrives tomorrow.", "Next bullet hits the target.",
        ]
        for input in examples {
            let result = SpokenListFormatter.format(input)
            XCTAssertEqual(result.text, input, input)
            XCTAssertFalse(result.containsList, input)
            XCTAssertNil(result.context, input)
        }
    }

    func testImplicitMarkerSeriesAndOrdinals() {
        XCTAssertEqual(SpokenListFormatter.format("One, apples. Two, bananas.").text, "1. apples\n2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("First, apples. Second, bananas.").text, "1. apples\n2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("3. oranges\n4. beach\n7. syrup").text, "3. oranges\n4. beach\n7. syrup")
        XCTAssertEqual(SpokenListFormatter.format("(3) oranges\n(7) syrup").text, "3. oranges\n7. syrup")
        XCTAssertEqual(SpokenListFormatter.format("- apples\n- bananas").text, "- apples\n- bananas")
        XCTAssertEqual(SpokenListFormatter.format("One, apples. 2. bananas.").text, "1. apples\n2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("One, apples, 2. bananas, three, oranges.").text, "1. apples\n2. bananas\n3. oranges")
        XCTAssertEqual(SpokenListFormatter.format("One, 2, three.").text, "One, 2, three.")
    }

    func testCommaSeparatedASRListsAndCountingContent() {
        XCTAssertEqual(SpokenListFormatter.format("One, apples, two, bananas, three, oranges.").text,
                       "1. apples\n2. bananas\n3. oranges")
        XCTAssertEqual(SpokenListFormatter.format("1. Apples, 2. Bananas").text, "1. Apples\n2. Bananas")
        let counting = SpokenListFormatter.format("Next item, one, two, three.", context: SpokenListContext(style: .numbered, nextNumber: 4))
        XCTAssertEqual(counting.text, "4. one, two, three")
        XCTAssertEqual(SpokenListFormatter.format("I counted one, two, three, four.").text, "I counted one, two, three, four.")
        XCTAssertEqual(SpokenListFormatter.format("Bullet point, apples, next bullet, bananas.").text, "- apples\n- bananas")
        XCTAssertEqual(SpokenListFormatter.format("Start a list. One — apples. Two - bananas.").text, "1. apples\n2. bananas")
    }

    func testTailMetadataDistinguishesMultilineItemsFromProse() {
        let item = SpokenListFormatter.format("Start a list. One, first paragraph\n\nsecond paragraph.")
        XCTAssertTrue(item.endsWithList)
        let prose = SpokenListFormatter.format("Start a list. One, oranges. End list. Please call tomorrow.")
        XCTAssertTrue(prose.containsList)
        XCTAssertFalse(prose.endsWithList)
        XCTAssertFalse(SpokenListFormatter.format("Plain text.").endsWithList)
    }

    func testCompoundNumbersAndExplicitMarkerVariants() {
        let result = SpokenListFormatter.format("Make a list. Twenty-one, apples. Number thirty two, bananas. Item one hundred and three, oranges.")
        XCTAssertEqual(result.text, "21. apples\n32. bananas\n103. oranges")
        XCTAssertEqual(result.context?.nextNumber, 104)
        XCTAssertEqual(SpokenListFormatter.format("Start a list. 1st, apples. 3rd, oranges.").text, "1. apples\n3. oranges")
    }

    func testItemContentKeepsDecimalsAbbreviationsSentencesAndParagraphs() {
        let result = SpokenListFormatter.format("Make a list. One, buy 3.5 litres for $12.50. Two, call Dr. Green in the U.S. Three, explain the problem. Include screenshots! Four, first paragraph\n\nsecond paragraph.")
        XCTAssertEqual(result.text, "1. buy 3.5 litres for $12.50\n2. call Dr. Green in the U.S.\n3. explain the problem. Include screenshots!\n4. first paragraph\n\nsecond paragraph")
    }

    func testSubstantivePreludeAndMarkedItemAreNotMistakenForMetaChatter() {
        let result = SpokenListFormatter.format("Please send the report tomorrow. Continue the list. Three, oranges.")
        XCTAssertEqual(result.text, "Please send the report tomorrow.\n\n3. oranges")
        let item = SpokenListFormatter.format("Make a list. One, my dictation was broken. Two, the screenshot was wrong.")
        XCTAssertEqual(item.text, "1. my dictation was broken\n2. the screenshot was wrong")
    }

    func testUnseparatedMarkerPhrasesNeedExistingListIntent() {
        let context = SpokenListContext(style: .numbered, nextNumber: 2)
        XCTAssertEqual(SpokenListFormatter.format("Number three oranges.", context: context).text, "3. oranges")
        XCTAssertEqual(SpokenListFormatter.format("Next item bananas.", context: context).text, "2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("Start a bulleted list. Bullet point apples.").text, "- apples")
        XCTAssertTrue(SpokenListFormatter.format("Next item").isControlOnly)
    }

    func testResumeDoesNotDeleteRecordingInstructionsQuestionsOrGenericProse() {
        for prelude in [
            "Please investigate why the recording failed.",
            "Why did my transcription fail?",
            "My recording failed.",
            "My recording of dictation failed.",
            "My dictation exercise failed.",
            "My microphone is broken.",
            "My dictation failed, can you investigate?",
            "Please redo my transcription again.",
        ] {
            let result = SpokenListFormatter.format("\(prelude) Continue the list. Three, oranges.")
            XCTAssertEqual(result.text, "\(prelude)\n\n3. oranges", prelude)
        }
        XCTAssertEqual(SpokenListFormatter.format("My voice to text was just ruined. Continue the list. Three, oranges.").text, "3. oranges")
    }
}
