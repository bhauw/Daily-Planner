import Testing
@testable import GoogleOAuthCore

@Suite("PKCE and OAuth state")
struct PKCETests {
    @Test("RFC 7636 example produces the expected S256 challenge")
    func knownVerifierProducesExpectedChallenge() throws {
        let pair = try PKCEPair(
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )

        #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pair.method == "S256")
    }

    @Test("Generated PKCE uses 64 random bytes and base64url encoding")
    func generatedVerifierHasRequiredEntropyAndAlphabet() throws {
        let pair = try PKCEPair.generate()

        #expect(pair.verifier.utf8.count == 86)
        #expect(pair.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(!pair.verifier.contains("="))
        #expect(pair.challenge.utf8.count == 43)
    }

    @Test("Generated state contains 256 bits of random input")
    func generatedStateHasRequiredEntropyAndAlphabet() throws {
        let state = try OAuthState.generate()

        #expect(state.utf8.count == 43)
        #expect(state.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(!state.contains("="))
    }

    @Test("Constant-time comparison distinguishes state values")
    func stateComparisonRejectsMismatch() {
        #expect(ConstantTime.equals("fixed-state", "fixed-state"))
        #expect(!ConstantTime.equals("fixed-state", "fixed-stata"))
        #expect(!ConstantTime.equals("fixed-state", "short"))
    }
}
