import Foundation

private struct Failure: Error { let message: String }
private func check(_ v: @autoclosure () -> Bool, _ m: String) throws {
    if !v() { throw Failure(message: m) }
}

/// 3.8을 들이면서 3.7을 남겼습니다. 두 모델이 함께 있는 동안 지켜져야 할 것들입니다.
@main private struct Runner {
    static func main() throws {
        try check(AIModel.gemini38Flash.rawValue == "gemini-3.8-flash", "3.8 identifier drifted")
        try check(AIModel.gemini37Flash.rawValue == "gemini-3.7-flash", "3.7 identifier drifted")

        // 3.7을 남긴 덕에 이관 표가 필요 없습니다. 저장값이 그대로 해석됩니다.
        try check(AIModel(storedValue: "gemini-3.7-flash") == .gemini37Flash, "a 3.7 room did not open as 3.7")
        try check(AIModel(storedValue: "gemini-3.8-flash") == .gemini38Flash, "a 3.8 room did not open as 3.8")

        // 이걸 놓치면 3.8이 "Gemini가 아닌 것"이 되어 API 호출이 막힙니다.
        try check(AIModel.gemini38Flash.isGemini, "3.8 is not counted as Gemini")
        try check(AIModel.gemini37Flash.isGemini, "3.7 is not counted as Gemini")
        try check(!AIModel.gpt56Luna.isGemini, "Luna is counted as Gemini")
        try check(AIModel.gemini38Flash.providerName == "Google", "3.8 provider drifted")
        try check(AIModel.gemini38Flash.shortName == "Gemini", "3.8 short name drifted")

        // 2026-09-02 공식 요금표 확인: 단가도 도입가 종료일도 3.7과 같습니다.
        try check(AIModel.gemini38Flash.inputPricePerMillion == AIModel.gemini37Flash.inputPricePerMillion, "input price differs")
        try check(AIModel.gemini38Flash.outputPricePerMillion == AIModel.gemini37Flash.outputPricePerMillion, "output price differs")
        try check(AIModel.gemini38Flash.cachedInputPricePerMillion == AIModel.gemini37Flash.cachedInputPricePerMillion, "cached price differs")
        try check(AIModel.gemini38Flash.cacheStoragePricePerMillionPerHour == AIModel.gemini37Flash.cacheStoragePricePerMillionPerHour, "cache storage price differs")
        try check(AIModel.gemini38Flash.cacheWriteMultiplier == AIModel.gemini37Flash.cacheWriteMultiplier, "cache write multiplier differs")

        try check(AIModel.gemini38Flash.displayName == "Gemini 3.8 Flash", "3.8 display name drifted")
        try check(AIModel.gemini37Flash.displayName == "Gemini 3.7 Flash", "3.7 display name drifted")
        // 목록에서 3.8이 먼저 옵니다.
        try check(AIModel.allCases.first == .gemini38Flash, "3.8 is not first in the list")

        print("17 gemini 3.8 model checks passed")
    }
}
