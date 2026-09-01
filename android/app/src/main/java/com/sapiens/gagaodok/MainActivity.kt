package com.sapiens.gagaodok

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.sapiens.gagaodok.sync.SyncRuntimeHost
import com.sapiens.gagaodok.sync.SyncRuntimeTrigger
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
import com.sapiens.gagaodok.ui.components.KakaoMenuHost
import com.sapiens.gagaodok.ui.screens.ChatRoomScreen
import com.sapiens.gagaodok.ui.screens.PersonaEditorScreen
import com.sapiens.gagaodok.ui.screens.ProfileScreen
import com.sapiens.gagaodok.ui.theme.GagaodokTheme
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.util.UUID

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // targetSdk 35에서는 어차피 기본값이지만, 명시해 두면 구형 기기에서도 같게 동작합니다.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        // 기본값이 전부 꺼짐이므로 이 연결만으로는 요청이 한 건도 나가지 않는다.
        // 화면을 열었다는 이유만으로 동기화가 시작되지 않는다.
        SyncRuntimeHost.run(SyncRuntimeTrigger.LAUNCH)
        lifecycle.addObserver(
            LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) {
                    SyncRuntimeHost.run(SyncRuntimeTrigger.FOREGROUND)
                }
            },
        )

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

                // 메뉴 카드는 여기 한 곳에서만 그립니다. 화면 안에서 띄우면 그 화면의
                // 자리만 어두워집니다(`KakaoMenuHost` 설명).
                KakaoMenuHost {
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
                        RootScreen(
                            onOpenRoom = { navController.navigate("room/$it") },
                            onOpenProfile = { navController.navigate("profile/$it") },
                            onEditPersona = { navController.navigate("persona/$it") },
                            tabletLayout = BuildConfig.TABLET_MENTOR
                        )
                    }
                    composable(
                        "room/{roomId}",
                        arguments = listOf(navArgument("roomId") { type = NavType.StringType })
                    ) { entry ->
                        val roomId = UUID.fromString(entry.arguments!!.getString("roomId"))
                        ChatRoomScreen(
                            roomId = roomId,
                            onBack = { navController.popBackStack() },
                            onEditPersona = { navController.navigate("persona/$roomId") },
                            onOpenProfile = { navController.navigate("profile/$roomId") },
                            tabletLayout = BuildConfig.TABLET_MENTOR
                        )
                    }
                    // 프로필은 옆이 아니라 **아래에서 올라옵니다.** 옆에서 밀려 들어오면
                    // 대화방과 같은 결이 되어, 목록의 다음 칸으로 넘어간 것처럼 읽힙니다.
                    composable(
                        "profile/{roomId}",
                        arguments = listOf(navArgument("roomId") { type = NavType.StringType }),
                        enterTransition = {
                            slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.Up, tween(240)) +
                                fadeIn(tween(160))
                        },
                        popExitTransition = {
                            slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.Down, tween(220)) +
                                fadeOut(tween(160))
                        }
                    ) { entry ->
                        val roomId = UUID.fromString(entry.arguments!!.getString("roomId"))
                        ProfileScreen(
                            roomId = roomId,
                            onBack = { navController.popBackStack() },
                            onOpenRoom = {
                                // 프로필을 거쳐 들어간 대화방에서 뒤로 가면 목록으로
                                // 돌아가야 합니다. 그냥 쌓으면 대화방 → 프로필 → 대화방이
                                // 되어 뒤로가기를 두 번 눌러야 합니다.
                                navController.navigate("room/$it") { popUpTo("root") }
                            },
                            onEditPersona = { navController.navigate("persona/$it") }
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
    }

    override fun onStop() {
        super.onStop()
        // 저장을 0.7초 모아서 하기 때문에, 이게 없으면 마지막 말풍선이 유실될 수 있습니다.
        // 안드로이드는 화면에서 사라진 앱을 언제든 메모리에서 내립니다.
        (applicationContext as GagaodokApp).run {
            chatStore.flushPendingSaves()
            inkStore.flushPendingSaves()
        }
    }
}
