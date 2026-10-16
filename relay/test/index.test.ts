import { expect, test } from "bun:test";
import worker from "../src/index";

test("Worker entry point exports a fetch handler", () => {
  expect(typeof worker.fetch).toBe("function");
});
