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

    private val _selectedModel = MutableStateFlow(
        prefs.getString(KEY_MODEL, null)?.let { AIModel.fromStoredValue(it) } ?: AIModel.GEMINI_37_FLASH
    )
    val selectedModel: StateFlow<AIModel> = _selectedModel

    fun setSelectedModel(model: AIModel) {
        _selectedModel.value = model
        prefs.edit().putString(KEY_MODEL, model.rawValue).apply()
    }

    private val _exchangeRate = MutableStateFlow(
        prefs.getFloat(KEY_EXCHANGE_RATE, 1420f).toDouble()
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

        @Volatile
        private var instance: AppSettings? = null

        fun get(context: Context): AppSettings =
            instance ?: synchronized(this) {
                instance ?: AppSettings(context).also { instance = it }
            }
    }
}
