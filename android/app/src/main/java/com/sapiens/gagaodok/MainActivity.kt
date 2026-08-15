package com.sapiens.gagaodok

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.sapiens.gagaodok.ui.RootScreen
import com.sapiens.gagaodok.ui.screens.ChatRoomScreen
import com.sapiens.gagaodok.ui.screens.PersonaEditorScreen
import com.sapiens.gagaodok.ui.theme.GagaodokTheme
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.util.UUID

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // targetSdk 35에서는 어차피 기본값이지만, 명시해 두면 구형 기기에서도 같게 동작합니다.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        val app = applicationContext as GagaodokApp

        setContent {
            val appearance by app.settings.appearance.collectAsState()

            GagaodokTheme(mode = appearance) {
                // 상태 표시줄·제스처 바의 아이콘 색을 앱 테마에 맞춥니다.
                //
                // `enableEdgeToEdge()`의 기본값은 **시스템** 다크 모드를 따라갑니다.
                // 앱에서 화면 모드를 따로 고를 수 있으므로, 시스템은 다크인데 앱은
                // 라이트인 조합에서 흰 배경 위에 흰 아이콘이 그려져 시계가 사라집니다.
                val dark = KakaoTheme.colors.isDark
                val view = LocalView.current
                LaunchedEffect(dark) {
                    val window = (view.context as android.app.Activity).window
                    WindowCompat.getInsetsController(window, view).apply {
                        isAppearanceLightStatusBars = !dark
                        isAppearanceLightNavigationBars = !dark
                    }
                }

                val navController = rememberNavController()

                NavHost(
                    navController = navController,
                    startDestination = "root",
                    modifier = Modifier
                        .fillMaxSize()
                        .background(KakaoTheme.colors.surface),
                    // 대화방은 오른쪽에서 밀려 들어오고 뒤로가기로 나갑니다.
                    // 안드로이드 표준이자 카카오톡 동작입니다.
                    enterTransition = {
                        slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.Left, tween(260))
                    },
                    exitTransition = {
                        slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.Left, tween(260))
                    },
                    popEnterTransition = {
                        slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.Right, tween(260))
                    },
                    popExitTransition = {
                        slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.Right, tween(260))
                    }
                ) {
                    composable("root") {
                        RootScreen(onOpenRoom = { navController.navigate("room/$it") })
                    }
                    composable(
                        "room/{roomId}",
                        arguments = listOf(navArgument("roomId") { type = NavType.StringType })
                    ) { entry ->
                        val roomId = UUID.fromString(entry.arguments!!.getString("roomId"))
                        ChatRoomScreen(
                            roomId = roomId,
                            onBack = { navController.popBackStack() },
                            onEditPersona = { navController.navigate("persona/$roomId") }
                        )
                    }
                    composable(
                        "persona/{roomId}",
                        arguments = listOf(navArgument("roomId") { type = NavType.StringType })
                    ) { entry ->
                        val roomId = UUID.fromString(entry.arguments!!.getString("roomId"))
                        PersonaEditorScreen(roomId = roomId, onBack = { navController.popBackStack() })
                    }
                }
            }
        }
    }

    override fun onStop() {
        super.onStop()
        // 저장을 0.7초 모아서 하기 때문에, 이게 없으면 마지막 말풍선이 유실될 수 있습니다.
        // 안드로이드는 화면에서 사라진 앱을 언제든 메모리에서 내립니다.
        (applicationContext as GagaodokApp).chatStore.flushPendingSaves()
    }
}
