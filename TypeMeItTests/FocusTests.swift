import Testing
@testable import TypeMeIt

struct FocusTests {
    @Test func textRolesAreTextInputs() {
        for role in Focus.textRoles {
            #expect(Focus.classifyRole(role, valueSettable: false) == true, "\(role)")
        }
    }

    @Test func genericRoleWithSettableValueIsTextInput() {
        #expect(Focus.classifyRole("AXWebArea", valueSettable: true) == true)
        #expect(Focus.classifyRole("AXGroup", valueSettable: true) == true)
    }

    @Test func staticContentIsNotTextInput() {
        for role in Focus.nonTextRoles {
            #expect(Focus.classifyRole(role, valueSettable: false) == false, "\(role)")
        }
    }

    @Test func controlWithSettableValueIsStillNotTextInput() {
        #expect(Focus.classifyRole("AXSlider", valueSettable: true) == false)
        #expect(Focus.classifyRole("AXCheckBox", valueSettable: true) == false)
    }

    @Test func genericRoleWithoutSettableValueIsUnknown() {
        #expect(Focus.classifyRole("AXWebArea", valueSettable: false) == nil)
        #expect(Focus.classifyRole("AXGroup", valueSettable: false) == nil)
        #expect(Focus.classifyRole("AXUnknown", valueSettable: false) == nil)
        #expect(Focus.classifyRole("", valueSettable: false) == nil)
    }

    @Test func containerAsFocusedElementIsUnknown() {
        // Zed reports its window; Java apps report the window or application.
        #expect(Focus.classifyRole("AXWindow", valueSettable: false) == nil)
        #expect(Focus.classifyRole("AXApplication", valueSettable: false) == nil)
        #expect(Focus.classifyRole("AXSheet", valueSettable: false) == nil)
    }

    @Test func roleListsDoNotOverlap() {
        #expect(Focus.nonTextRoles.isDisjoint(with: Focus.textRoles))
    }

    @Test func secureRoleOrSubroleIsSecure() {
        #expect(Focus.roleIsSecure("AXSecureTextField", subrole: nil))
        #expect(Focus.roleIsSecure("AXTextField", subrole: "AXSecureTextField"))
        #expect(Focus.roleIsSecure("AXSecureTextField", subrole: "AXSecureTextField"))
    }

    @Test func plainTextFieldIsNotSecure() {
        #expect(!Focus.roleIsSecure("AXTextField", subrole: nil))
        #expect(!Focus.roleIsSecure("AXTextField", subrole: "AXSearchField"))
        #expect(!Focus.roleIsSecure("AXTextArea", subrole: ""))
        #expect(!Focus.roleIsSecure("", subrole: nil))
    }

    @Test func utf16RangeAcceptsNonNegativeBounds() {
        #expect(Focus.utf16Range(location: 0, length: 0) == 0..<0)
        #expect(Focus.utf16Range(location: 7, length: 3) == 7..<10)
    }

    @Test func utf16RangeRejectsNegativeBounds() {
        #expect(Focus.utf16Range(location: -1, length: 0) == nil)
        #expect(Focus.utf16Range(location: 0, length: -1) == nil)
        #expect(Focus.utf16Range(location: -1, length: -1) == nil)
    }
}
