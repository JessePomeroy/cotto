import { describe, expect, test } from "bun:test";
import { formatSpokenList, replaceFormattedText } from "../src/domain/lists.ts";

const numbered = (nextNumber = 1) => ({ style: "numbered" as const, nextNumber });

describe("spoken-list grammar parity with the Swift client", () => {
  const formattedExamples = [
    ["One, apples. Two, bananas.", "1. apples\n2. bananas"],
    ["First, apples. Second, bananas.", "1. apples\n2. bananas"],
    ["3. oranges\n4. beach\n7. syrup", "3. oranges\n4. beach\n7. syrup"],
    ["(3) oranges\n(7) syrup", "3. oranges\n7. syrup"],
    ["- apples\n- bananas", "- apples\n- bananas"],
    ["One, apples. 2. bananas.", "1. apples\n2. bananas"],
    ["One, apples, 2. bananas, three, oranges.", "1. apples\n2. bananas\n3. oranges"],
    ["One, apples, two, bananas, three, oranges.", "1. apples\n2. bananas\n3. oranges"],
    ["1. Apples, 2. Bananas", "1. Apples\n2. Bananas"],
    ["Bullet point, apples, next bullet, bananas.", "- apples\n- bananas"],
    ["Start a list. One — apples. Two - bananas.", "1. apples\n2. bananas"],
    ["Start a list. 24. End list.", "1. 24"],
    ["Start a list. 24. Next item, agreed.", "1. 24\n2. agreed"],
    ["Make a list. Twenty-one, apples. Number thirty two, bananas. Item one hundred and three, oranges.", "21. apples\n32. bananas\n103. oranges"],
    ["Start a list. 1st, apples. 3rd, oranges.", "1. apples\n3. oranges"],
    ["Make a list. One, buy 3.5 litres for $12.50. Two, call Dr. Green in the U.S. Three, explain the problem. Include screenshots! Four, first paragraph\n\nsecond paragraph.", "1. buy 3.5 litres for $12.50\n2. call Dr. Green in the U.S.\n3. explain the problem. Include screenshots!\n4. first paragraph\n\nsecond paragraph"],
    ["Please send the report tomorrow. Continue the list. Three, oranges.", "Please send the report tomorrow.\n\n3. oranges"],
    ["Make a list. One, my dictation was broken. Two, the screenshot was wrong.", "1. my dictation was broken\n2. the screenshot was wrong"],
    ["Start a bulleted list. Bullet point apples.", "- apples"],
    ["Start a list. Number five is book the room. 3 is pick up the keys. Item two is send the invitation.", "5. book the room\n3. pick up the keys\n2. send the invitation"],
  ] as const;
  for (const [source, expected] of formattedExamples) {
    test(source, () => {
      const result = formatSpokenList(source);
      expect(result.text).toBe(expected);
      expect(result.containsList).toBe(true);
      expect(result.formattingRejectionReason).toBeUndefined();
    });
  }

  const ordinaryExamples = [
    "I bought three oranges.", "Call at four.", "One thing matters.", "First we test. Second we ship.", "First we test.\n\nSecond we ship.",
    "We need 3.5 litres and $12.50 for lunch.", "Meet at 4:30 on 2026-09-03.", "Use 1/2 cup of sugar and 3/4 cup of flour.",
    "One, two, three.", "One, 2, three.", "2026. Revenue increased. 2027. We expect growth.", "The end of the list is missing.",
    "Make a list of my expenses for tomorrow.", "Sorry, I wanted that screenshot. My voice to text was just ruined.",
    "Item 123 is missing.", "Number one is our priority.", "New item added to the cart.", "Bullet point formatting is broken.",
    "Next item arrives tomorrow.", "Next bullet hits the target.", "One is enough. Three is excessive.",
    "This one is ready. That one is missing.", "I have a list. This one is ready. That one is missing.",
    "I have a list. One is missing.", "First is not necessarily best.", "I counted one, two, three, four.",
  ];
  for (const source of ordinaryExamples) {
    test(`ordinary prose: ${source}`, () => {
      const result = formatSpokenList(source);
      expect(result.text).toBe(source);
      expect(result.containsList).toBe(false);
      expect(result.context).toBeUndefined();
      expect(result.formattingRejectionReason).toBeUndefined();
    });
  }

  test("announced copular markers keep repeats, skips and decreases", () => {
    const source = "Okay, I have a list of things to do today. One is I need to book the room Three is I need to pick up the keys. Two is I need to send the invitation. Four is I need to check the meeting room.";
    expect(formatSpokenList(source).text).toBe("Okay, I have a list of things to do today.\n\n1. I need to book the room\n3. I need to pick up the keys\n2. I need to send the invitation\n4. I need to check the meeting room");
    for (const introduction of ["I have a list.", "Here's my numbered list.", "We have a list.", "Start a list."]) {
      const result = formatSpokenList(`${introduction} Five is book the room. Three is check that this one is available. Three is call the host.`);
      expect(result.text.endsWith("5. book the room\n3. check that this one is available\n3. call the host")).toBe(true);
      expect(result.context).toEqual(numbered(4));
      expect(result.formattingRejectionReason).toBeUndefined();
    }
  });

  test("explicit and implicit continuations advance only emitted items", () => {
    const first = formatSpokenList("Make a list. One, apples. Two, bananas.");
    expect(first.context).toEqual(numbered(3));
    const next = formatSpokenList("Next item, oranges.", first.context);
    expect(next.text).toBe("3. oranges");
    expect(next.continuesPreviousList).toBe(true);
    const resumed = formatSpokenList("Continue the list. Number four, a trip to the beach. Item seven, more syrup.", next.context);
    expect(resumed.text).toBe("4. a trip to the beach\n7. more syrup");
    expect(resumed.context).toEqual(numbered(8));
    expect(resumed.continuesPreviousList).toBe(true);
    expect(formatSpokenList("Maple syrup.", resumed.context).text).toBe("8. Maple syrup");
    expect(formatSpokenList("Number three oranges.", numbered(2)).text).toBe("3. oranges");
    expect(formatSpokenList("Next item bananas.", numbered(2)).text).toBe("2. bananas");
    expect(formatSpokenList("Next item, one, two, three.", numbered(4)).text).toBe("4. one, two, three");
  });

  test("resume removes only explicit tool chatter", () => {
    const prelude = "Sorry, I wanted that screenshot. Go ahead. My voice to text was just ruined. Let me go back to where I was with that list.";
    const result = formatSpokenList(`${prelude} Three, oranges. Four, a trip to the beach. Seven, more syrup. That's the end of the list.`);
    expect(result.text).toBe("3. oranges\n4. a trip to the beach\n7. more syrup");
    expect(result.context).toBeUndefined();
    expect(result.endedList).toBe(true);
    expect(result.continuesPreviousList).toBe(false);
    const continued = formatSpokenList(`${prelude} Next item, oranges.`, numbered(3));
    expect(continued.text).toBe("3. oranges");
    expect(continued.context).toEqual(numbered(4));
    expect(continued.continuesPreviousList).toBe(true);
    for (const kept of ["Please investigate why the recording failed.", "Why did my transcription fail?", "My recording failed.", "My recording of dictation failed.", "My dictation exercise failed.", "My microphone is broken.", "My dictation failed, can you investigate?", "Please redo my transcription again."]) {
      expect(formatSpokenList(`${kept} Continue the list. Three, oranges.`).text).toBe(`${kept}\n\n3. oranges`);
    }
  });

  test("controls and silence preserve continuation without adding content", () => {
    const context = numbered(3);
    for (const command of ["Resume the list.", "Continue this list", "Next item.", "Let me go back to the list."]) {
      const result = formatSpokenList(command, context);
      expect(result.isControlOnly).toBe(true);
      expect(result.continuesPreviousList).toBe(true);
      expect(result.context).toEqual(context);
      expect(result.endsWithList).toBe(false);
    }
    for (const text of ["", "  ", "\n\n"]) {
      const result = formatSpokenList(text, context);
      expect(result.text).toBe("");
      expect(result.context).toEqual(context);
      expect(result.isControlOnly).toBe(false);
      expect(result.endedList).toBe(false);
    }
    expect(formatSpokenList("Next item").isControlOnly).toBe(true);
    const start = formatSpokenList("Start a numbered list.");
    expect(start.isControlOnly).toBe(true);
    expect(start.containsList).toBe(false);
    expect(start.context).toEqual(numbered());
    expect(formatSpokenList("Next item.", start.context).context).toEqual(numbered());
    const restarted = formatSpokenList("End list. Start a new list.", context);
    expect(restarted.isControlOnly).toBe(true);
    expect(restarted.continuesPreviousList).toBe(false);
    expect(restarted.context).toEqual(numbered());
    expect(formatSpokenList("Start a new list. One, pears.", numbered(8)).continuesPreviousList).toBe(false);
    expect(formatSpokenList("Start a list. Next item. End list.").formattingRejectionReason).toBeUndefined();
  });

  test("bullets continue and explicit end returns to prose", () => {
    const first = formatSpokenList("Start a bulleted list. Bullet point, apples. Next bullet, bananas.");
    expect(first.text).toBe("- apples\n- bananas");
    const next = formatSpokenList("Continue the list. Next item, oranges.", first.context);
    expect(next.text).toBe("- oranges");
    expect(next.continuesPreviousList).toBe(true);
    const end = formatSpokenList("That's the end of the list.", next.context);
    expect(end.text).toBe("");
    expect(end.isControlOnly).toBe(true);
    expect(end.endedList).toBe(true);
    expect(end.context).toBeUndefined();
    const prose = formatSpokenList("Three, oranges. End of list. Please send the receipt tomorrow.", numbered(3));
    expect(prose.text).toBe("3. oranges\n\nPlease send the receipt tomorrow.");
    expect(prose.endsWithList).toBe(false);
    expect(prose.context).toBeUndefined();
    expect(formatSpokenList("Start a list. One, first paragraph\n\nsecond paragraph.").endsWithList).toBe(true);
  });

  test("numeric answers and corrections remain dictated content", () => {
    for (const [source, expected] of [["24.", "5. 24"], ["24)", "5. 24)"], ["24:", "5. 24:"], ["(24)", "5. (24)"]] as const) {
      const plain = formatSpokenList(source);
      expect(plain.text).toBe(source);
      expect(plain.isControlOnly).toBe(false);
      const item = formatSpokenList(source, numbered(5));
      expect(item.text).toBe(expected);
      expect(item.context).toEqual(numbered(6));
      expect(item.continuesPreviousList).toBe(true);
      expect(item.formattingRejectionReason).toBeUndefined();
    }
    for (const source of ["Make it 42, err, 24.", "Make it 42, err, 24. That is final."]) {
      expect(formatSpokenList(source).text).toBe(source);
      const item = formatSpokenList(source, numbered(5));
      expect(item.text.startsWith("5. Make it 42, err, 24")).toBe(true);
      expect(item.context).toEqual(numbered(6));
      expect(item.formattingRejectionReason).toBeUndefined();
    }
  });

  test("ASR missing punctuation needs an anchored increasing series", () => {
    for (const [source, expected, next] of [
      ["5, Apples 6, Bananas 7, Oranges 8, Pears", "5. Apples\n6. Bananas\n7. Oranges\n8. Pears", 9],
      ["5, apples 7, oranges", "5. apples\n7. oranges", 8],
      ["Continue the list. 5, apples 7, oranges", "5. apples\n7. oranges", 8],
    ] as const) {
      for (const context of [undefined, numbered(20)]) {
        const result = formatSpokenList(source, context);
        expect(result.text).toBe(expected);
        expect(result.context).toEqual(numbered(next));
        expect(result.formattingRejectionReason).toBeUndefined();
      }
    }
    for (const source of ["We have 5, maybe 6, apples.", "I said 24, 25, and 26.", "5, maybe 6, perhaps 7, people.", "The range is 5, approximately 6, perhaps 7, units.", "The answer is: 24. That is final.", "5, 6, 7, 8.", "We need 3.5 litres and $12.50 for lunch.", "Meet at 4:30 on 2026-09-03.", "2026. Revenue increased. 2027. We expect growth."]) {
      expect(formatSpokenList(source).text).toBe(source);
      const item = formatSpokenList(source, numbered(3));
      expect(item.text.startsWith("3. ")).toBe(true);
      expect(item.text.includes("\n")).toBe(false);
      expect(item.context).toEqual(numbered(4));
      expect(item.formattingRejectionReason).toBeUndefined();
    }
  });

  test("diagnostic control spans use UTF-16 and exclude numbers and item text", () => {
    const source = "Please keep café 🦜. Continue the list. Number twenty-four, oranges. End list.";
    const result = formatSpokenList(source);
    expect(result.text).toBe("Please keep café 🦜.\n\n24. oranges");
    expect(result.consumedControls.map(({ location, length }) => source.slice(location, location + length))).toEqual(["Continue the list.", "End list."]);
    expect(result.consumedControls[0]?.location).toBe(source.indexOf("Continue"));
    expect(replaceFormattedText(result, "Updated").consumedControls).toEqual(result.consumedControls);
    expect(formatSpokenList("Start a list. One, café. Two, 👨‍👩‍👧‍👦 family.").text).toBe("1. café\n2. 👨‍👩‍👧‍👦 family");
  });
});
