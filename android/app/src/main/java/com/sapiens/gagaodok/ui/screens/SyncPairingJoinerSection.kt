package com.sapiens.gagaodok.ui.screens

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.sync.KeystoreSyncSecretVault
import com.sapiens.gagaodok.sync.OkHttpSyncTransport
import com.sapiens.gagaodok.sync.SyncConnectionLoadResult
import com.sapiens.gagaodok.sync.SyncConnectionStateStore
import com.sapiens.gagaodok.sync.SyncPairingClient
import com.sapiens.gagaodok.sync.SyncPairingJoinerCoordinator
import com.sapiens.gagaodok.sync.SyncPairingJoinerService
import com.sapiens.gagaodok.sync.SyncPairingJoinerUiError
import com.sapiens.gagaodok.sync.SyncPairingJoinerUiModel
import com.sapiens.gagaodok.sync.SyncPairingJoinerUiState
import com.sapiens.gagaodok.sync.SyncAccountTransitionCoordinator
import com.sapiens.gagaodok.sync.SyncTransitionAvailability
import com.sapiens.gagaodok.sync.SyncTransitionPairingJoinerService
import com.sapiens.gagaodok.sync.SyncCandidateBootstrapper
import com.sapiens.gagaodok.sync.DefaultSyncPairingCandidateFlow
import com.sapiens.gagaodok.sync.SyncSecretLoadResult
import com.sapiens.gagaodok.sync.SyncSecretStore
import com.sapiens.gagaodok.sync.SyncSyntheticEnvironment
import com.sapiens.gagaodok.sync.SystemSyncRandomSource
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Join an account already shown on a Mac. Existing local sync state is never overwritten. */
@Composable
internal fun SyncPairingJoinerSection(
    environment: SyncSyntheticEnvironment,
    transition: SyncAccountTransitionCoordinator? = null,
) {
    val context = LocalContext.current
    val model = remember(environment, transition) { buildPairingJoinerModel(context, environment, transition) } ?: return
    val state by model.state.collectAsState()
    val colors = KakaoTheme.colors
    val scope = rememberCoroutineScope()
    var scannerVisible by remember { mutableStateOf(false) }

    fun openScannerAfterPermission() {
        model.cameraPermissionGranted()
        scannerVisible = model.state.value == SyncPairingJoinerUiState.Scanning
    }

    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) openScannerAfterPermission() else model.cameraDenied()
    }

    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = 14.dp)
            .background(colors.surface, RoundedCornerShape(10.dp))
            .padding(12.dp),
    ) {
        Text(
            "기존 계정에 이 기기 합류",
            style = KakaoText.listName.copy(fontWeight = FontWeight.Bold),
            color = colors.textPrimary,
        )
        Text(
            pairingDetail(state),
            style = KakaoText.caption,
            color = colors.textSecondary,
            modifier = Modifier.padding(top = 4.dp),
        )

        Row(
            Modifier.fillMaxWidth().padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (model.actions.canRequestScan) {
                PairingAction("앱에서 QR 스캔") {
                    model.requestScan()
                    if (!model.actions.canLaunchCamera) return@PairingAction
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        openScannerAfterPermission()
                    } else {
                        cameraPermission.launch(Manifest.permission.CAMERA)
                    }
                }
            }
            if (model.actions.canConfirmSas) {
                PairingAction("맥과 번호 확인") {
                    scope.launch { withContext(Dispatchers.IO) { model.confirmSasAndRedeem() } }
                }
            }
        }
    }

    if (scannerVisible) {
        Dialog(
            onDismissRequest = {
                scannerVisible = false
                model.cameraDenied()
            },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            SyncPairingScanner(
                onScanned = { payload ->
                    scannerVisible = false
                    scope.launch {
                        withContext(Dispatchers.IO) {
                            model.acceptScannedPayload(
                                payload,
                                environment.device_id,
                                if (BuildConfig.TABLET_MENTOR) "TABLET_SPACE" else "PHONE_SPACE",
                                if (BuildConfig.TABLET_MENTOR) "android_tablet" else "android_phone",
                            )
                        }
                    }
                },
                onCancel = {
                    scannerVisible = false
                    model.cameraDenied()
                },
            )
        }
    }
}

@Composable
private fun PairingAction(title: String, action: () -> Unit) {
    val colors = KakaoTheme.colors
    Text(
        title,
        style = KakaoText.caption,
        color = colors.bubbleMineText,
        modifier = Modifier
            .background(colors.bubbleMine, RoundedCornerShape(8.dp))
            .clickable(onClick = action)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

private fun buildPairingJoinerModel(
    context: Context,
    environment: SyncSyntheticEnvironment,
    transition: SyncAccountTransitionCoordinator?,
): SyncPairingJoinerUiModel? = runCatching {
    val secretStore = SyncSecretStore(context)
    val vault = KeystoreSyncSecretVault(secretStore)
    val connection = SyncConnectionStateStore(File(context.filesDir, "sync/connection.json"))
    val available = {
        if (transition == null) {
            vault.load() is SyncSecretLoadResult.Absent && connection.load() is SyncConnectionLoadResult.Absent
        } else {
            transition.availability() == SyncTransitionAvailability.READY
        }
    }
    if (!available()) return@runCatching null
    val pairingClient = SyncPairingClient(environment.base_url, { null }, OkHttpSyncTransport())
    val pairingCoordinator = SyncPairingJoinerCoordinator(SystemSyncRandomSource(), vault, connection)
    val service = if (transition == null) {
        SyncPairingJoinerService(pairingCoordinator, pairingClient)
    } else {
        SyncTransitionPairingJoinerService(
            DefaultSyncPairingCandidateFlow(pairingCoordinator, pairingClient),
            SyncCandidateBootstrapper(context.filesDir, OkHttpSyncTransport()),
            transition,
        )
    }
    SyncPairingJoinerUiModel(
        service = service,
        available = available,
    )
}.getOrNull()

private fun pairingDetail(state: SyncPairingJoinerUiState): String = when (state) {
    SyncPairingJoinerUiState.Idle -> "맥의 설정에서 새 기기 합류 QR을 연 뒤 스캔하세요."
    SyncPairingJoinerUiState.RequestingCamera -> "카메라 사용을 허용해야 QR을 읽을 수 있습니다."
    SyncPairingJoinerUiState.Scanning -> "QR을 찾는 중입니다. QR 값은 화면이나 로그에 표시하지 않습니다."
    is SyncPairingJoinerUiState.VerifySas -> "맥 화면과 이 번호가 같은지 확인하세요: ${state.digits}"
    is SyncPairingJoinerUiState.WaitingApproval ->
        "맥 화면과 이 번호가 같은지 확인한 뒤 승인 결과를 다시 확인하세요: ${state.digits}\n" +
            "여러 번 눌러도 그대로면 맥에서 아직 승인하지 않은 것입니다."
    SyncPairingJoinerUiState.Redeeming -> "승인 결과를 확인하고 있습니다."
    SyncPairingJoinerUiState.LinkedSyncOff -> "계정에 합류했습니다. 실제 대화 동기화는 꺼져 있습니다."
    is SyncPairingJoinerUiState.Error -> when (state.reason) {
        SyncPairingJoinerUiError.CameraDenied -> "카메라 스캔이 취소됐습니다. 다시 시도할 수 있습니다."
        SyncPairingJoinerUiError.NotAvailable -> "기존 연결 정보가 있어 덮어쓰지 않았습니다."
        SyncPairingJoinerUiError.InvalidQr -> "가가오독 합류 QR이 아닙니다. 새 QR로 다시 시도하세요."
        SyncPairingJoinerUiError.PairingFailed -> "합류를 완료하지 못했습니다. 맥의 세션을 확인하세요."
        SyncPairingJoinerUiError.DeliveryUnreadable ->
            "서버에는 합류가 기록됐지만 이 기기가 계정 키를 열지 못했습니다. " +
                "다시 눌러도 같은 결과가 나옵니다. 맥에서 이 기기의 연결을 지운 뒤 새 QR로 다시 시작하세요."
    }
}
