package com.sapiens.gagaodok.data

import android.content.Context
import com.sapiens.gagaodok.model.AIModel
import com.sapiens.gagaodok.ui.theme.AppearanceMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/// 앱 전역 설정입니다. 맥 판의 `UserDefaults` 자리입니다.
///
/// 값이 몇 개 안 되고 켤 때 바로 읽어야 해서 DataStore 대신 SharedPreferences를 씁니다.
/// DataStore는 비동기라 첫 화면이 잘못된 테마로 한 번 깜빡입니다.
class AppSettings private constructor(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("gagaodok_settings", Context.MODE_PRIVATE)

    private val _appearance = MutableStateFlow(
        AppearanceMode.fromRawValue(prefs.getString(KEY_APPEARANCE, null))
    )
    val appearance: StateFlow<AppearanceMode> = _appearance

    fun setAppearance(mode: AppearanceMode) {
        _appearance.value = mode
        prefs.edit().putString(KEY_APPEARANCE, mode.rawValue).apply()
    }

    // 저장해 둔 선택을 실제로 읽어 옵니다.
    //
    // 예전에는 이 자리에 3.7이 박혀 있었고 setter도 인자를 버린 채 3.7만 썼습니다.
    // 대화 모델이 하나뿐이라 티가 나지 않았을 뿐, 저장은 하고 읽지는 않는 상태였습니다.
    // 모델이 둘이 된 지금은 골라도 아무 일이 없는 것으로 드러납니다.
    private val _selectedModel = MutableStateFlow(
        AIModel.fromStoredValue(prefs.getString(KEY_MODEL, null) ?: "") ?: AIModel.GEMINI_38_FLASH
    )
    val selectedModel: StateFlow<AIModel> = _selectedModel

    fun setSelectedModel(model: AIModel) {
        _selectedModel.value = model
        prefs.edit().putString(KEY_MODEL, model.rawValue).apply()
    }

    private val _exchangeRate = MutableStateFlow(
        prefs.getFloat(KEY_EXCHANGE_RATE, DEFAULT_EXCHANGE_RATE.toFloat()).toDouble()
    )
    val exchangeRate: StateFlow<Double> = _exchangeRate

    fun setExchangeRate(rate: Double) {
        if (rate <= 0) return
        _exchangeRate.value = rate
        prefs.edit().putFloat(KEY_EXCHANGE_RATE, rate.toFloat()).apply()
    }

    companion object {
        private const val KEY_APPEARANCE = "appearanceMode"
        private const val KEY_MODEL = "selectedAIModel"
        private const val KEY_EXCHANGE_RATE = "usageExchangeRate"

        /// 실제 청구서에서 역산한 값입니다. 예전 1,420은 근거 없이 정한 값이었습니다.
        ///
        /// 2026-09-02~09-15 폰 청구서 세 항목이 모두 같은 값을 가리킵니다.
        ///   입력    6,085,703 × $0.75/M  = $4.5643 → ₩6,314 → 1,383
        ///   캐시읽기 34,537,934 × $0.075/M = $2.5903 → ₩3,583 → 1,383
        ///   출력      339,611 × $3.75/M  = $1.2735 → ₩1,762 → 1,384
        ///
        /// 구글이 환율을 다시 정하면 어긋납니다. 화면에서 사용자가 고칠 수 있습니다.
        const val DEFAULT_EXCHANGE_RATE = 1383.0

        @Volatile
        private var instance: AppSettings? = null

        fun get(context: Context): AppSettings =
            instance ?: synchronized(this) {
                instance ?: AppSettings(context).also { instance = it }
            }
    }
}
