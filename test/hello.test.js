import { test, expect } from "bun:test";

test("matchers", () => {
  expect.assertions(3);
  
  expect({}).toBeObject();
  expect(" foo ").toEqualIgnoringWhitespace("foo");
  expect("foo").toBeOneOf(["foo", "bar"]);
});

