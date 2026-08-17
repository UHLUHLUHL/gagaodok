package com.sapiens.gagaodok

import android.app.Application
import com.sapiens.gagaodok.data.AppSettings
import com.sapiens.gagaodok.data.ChatStore
import com.sapiens.gagaodok.data.MyProfileStore
import com.sapiens.gagaodok.data.TokenUsageStore

/// 앱이 살아 있는 동안 하나뿐인 것들이 여기서 시작합니다.
///
/// 맥 판은 `.shared` 싱글턴을 그대로 썼지만 안드로이드는 프로세스가 언제든 죽고
/// 다시 살아나므로, 만들어지는 자리를 한 곳으로 모아 둡니다.
class GagaodokApp : Application() {

    lateinit var chatStore: ChatStore
        private set
    lateinit var settings: AppSettings
        private set
    lateinit var usage: TokenUsageStore
        private set
    lateinit var myProfile: MyProfileStore
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        chatStore = ChatStore.get(this)
        settings = AppSettings.get(this)
        usage = TokenUsageStore.get(this)
        myProfile = MyProfileStore.get(this)
    }

    companion object {
        lateinit var instance: GagaodokApp
            private set
    }
}
