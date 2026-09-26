#!/bin/sh
# Runs the clean-up XCTest files against a variant's sources, without xcodebuild.
# usage: unit/run.sh <variant-dir>
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(cd "$HERE/../../.." && pwd)/TypeMeItTests"
V="$(cd "$1" && pwd)"
B="$(cd "$HERE/../../.." && pwd)/build/postprocess-lab/unit-$(basename "$V")"
rm -rf "$B"; mkdir -p "$B"
python3 - "$T" "$B" <<'PY'
import re, sys, os
src, out = sys.argv[1], sys.argv[2]
calls = []
for f in ['WritingStyleTests.swift', 'LocalCleanupTests.swift', 'PostProcessorTests.swift', 'CustomWordMatcherTests.swift', 'ScreenContextTests.swift']:
    s = open(os.path.join(src, f)).read()
    s = re.sub(r'^\s*(@testable )?import (XCTest|TypeMeIt)\s*$', '', s, flags=re.M)
    # Drop test methods that need sources outside clean-up (the Transcriber).
    while True:
        m = next((m for m in re.finditer(r'\n\s*func (test\w+)\(\)[^{]*\{', s) if 'Transcriber.' in s[m.end():s.find('\n    func ', m.end()) if s.find('\n    func ', m.end()) != -1 else len(s)]), None)
        if not m: break
        depth, i = 1, m.end()
        while depth: depth += {'{': 1, '}': -1}.get(s[i], 0); i += 1
        s = s[:m.start()] + s[i:]
    open(os.path.join(out, f), 'w').write(s)
    for cls in re.findall(r'class (\w+)\s*:\s*XCTestCase', s):
        body = s[s.index('class ' + cls):]
        for m in re.findall(r'func (test\w+)\(\)', body):
            calls.append(f'currentTest = "{cls}.{m}"; {cls}().{m}()')
shim = '''import Foundation
class XCTestCase { required init() {} }
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var assertions = 0
nonisolated(unsafe) var currentTest = ""
func report(_ ok: Bool, _ detail: String, _ file: StaticString, _ line: UInt) {
    assertions += 1
    if !ok { failures += 1; print("FAIL \\(currentTest) (\\((("\\(file)" as NSString).lastPathComponent)):\\(line))\\n\\(detail)") }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let x = try! a(), y = try! b(); report(x == y, "   got:  \\(String(reflecting: x))\\n   want: \\(String(reflecting: y))", file, line)
}
func XCTAssertTrue(_ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) { report(try! a(), "   expected true", file, line) }
func XCTAssertFalse(_ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) { report(!(try! a()), "   expected false", file, line) }
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) { report((try! a()) == nil, "   expected nil", file, line) }
'''
open(os.path.join(out, 'Shim.swift'), 'w').write(shim)
open(os.path.join(out, 'main.swift'), 'w').write('\n'.join(calls) + '\nprint("\\(assertions - failures)/\\(assertions) assertions passed, \\(failures) failed")\n')
print(len(calls), 'tests')
PY
swiftc -O -enable-bare-slash-regex "$B"/*.swift "$V"/*.swift -o "$B/unit" 2>&1 | grep -E 'error' -A6 | head -30
"$B/unit"
