package com.sapiens.gagaodok.ui.screens

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.sapiens.gagaodok.BuildConfig
import com.sapiens.gagaodok.sync.KeystoreSyncSecretVault
import com.sapiens.gagaodok.sync.OkHttpSyncTransport
import com.sapiens.gagaodok.sync.SyncConnectionStateStore
import com.sapiens.gagaodok.sync.SyncEnrollmentJournal
import com.sapiens.gagaodok.sync.SyncOnboardingCoordinator
import com.sapiens.gagaodok.sync.SyncOnboardingIdentity
import com.sapiens.gagaodok.sync.SyncOnboardingModel
import com.sapiens.gagaodok.sync.SyncOnboardingUiError
import com.sapiens.gagaodok.sync.SyncOnboardingUiState
import com.sapiens.gagaodok.sync.SyncPullCoordinator
import com.sapiens.gagaodok.sync.SyncRecoveryMnemonic
import com.sapiens.gagaodok.sync.SyncReplicaStore
import com.sapiens.gagaodok.sync.SyncSecretLoadResult
import com.sapiens.gagaodok.sync.SyncSecretStore
import com.sapiens.gagaodok.sync.SyncSyntheticEnvironment
import com.sapiens.gagaodok.sync.SyncWorkerClient
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The synthetic-test sync onboarding section.
 *
 * A screen with no side effects of its own. Appearing calls only `refresh()`,
 * which reads stored status and returns; everything that sends a request,
 * stores a secret or writes the replica is behind a button. Which buttons exist
 * comes from the model's `actions` rather than from conditions written here, so
 * a composable cannot offer an action the state machine considers unsafe.
 *
 * This section never reads or writes a conversation. What a successful walk
 * fills is the opaque shadow replica, which no conversation screen consults.
 *
 * It is shown on both flavours. The canonical user decisions govern which
 * *rooms* appear on which device; none of them makes device enrollment itself a
 * phone-only or tablet-only surface, so gating it here would be inventing a
 * product rule rather than following one. The space and platform the device
 * enrolls as do follow the flavour.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SyncSettingsSection() {
    val colors = KakaoTheme.colors
    val context = LocalContext.current
    val environment = remember { SyncSyntheticEnvironment.load(SyncSyntheticEnvironment.file(context)) }
    val model = remember(environment) { environment?.let { buildModel(context, it) } }

    Column(Modifier.fillMaxWidth().padding(14.dp)) {
        Text(
            "시험용 합성 계정만 연결합니다. 이 화면은 실제 대화를 읽거나 올리지 않습니다.",
            style = KakaoText.caption,
            color = colors.textSecondary,
        )

        if (model == null || environment == null) {
            Text(
                "합성 시험 환경이 설정되어 있지 않습니다. 설정 파일이 없으면 이 화면은 아무것도 하지 않습니다.",
                style = KakaoText.caption,
                color = colors.textTertiary,
                modifier = Modifier.padding(top = 8.dp),
            )
            return@Column
        }

        val state by model.state.collectAsState()
        val phrase by model.recoveryPhrase.collectAsState()
        val confirmingDisconnect by model.disconnectConfirmationVisible.collectAsState()
        val actions = model.actions

        // Reading stored status is the only thing that happens without a press.
        LaunchedEffect(model) { withContext(Dispatchers.IO) { model.refresh() } }

        Column(Modifier.fillMaxWidth().padding(top = 10.dp)) {
            Text(statusTitle(state), style = KakaoText.listName, color = colors.textPrimary)
            Text(
                statusDetail(state),
                style = KakaoText.caption,
                color = colors.textSecondary,
                modifier = Modifier.padding(top = 2.dp),
            )
        }

        phrase?.let { shown ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 10.dp)
                    .background(colors.surface, RoundedCornerShape(10.dp))
                    .padding(12.dp),
            ) {
                Text(
                    "복구 문구 (한 번만 표시됩니다)",
                    style = KakaoText.listName.copy(fontWeight = FontWeight.Bold),
                    color = colors.textPrimary,
                )
                Text(shown, style = KakaoText.listPreview, color = colors.textPrimary, modifier = Modifier.padding(top = 6.dp))
                Text(
                    "이 문구는 어디에도 저장되지 않습니다. 종이에 적어 따로 보관한 뒤 아래 버튼을 누르십시오. " +
                        "문구를 잃고 연결된 기기도 모두 잃으면 복구할 수 없습니다.",
                    style = KakaoText.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }

        FlowRow(
            Modifier.fillMaxWidth().padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (actions.canBeginConnection) SyncActionButton("합성 계정 연결 준비") { model.beginConnection() }
            if (actions.canConfirmPhrase) SyncActionButton("문구를 적어 두었습니다") { model.confirmPhraseSaved() }
            if (actions.canRetryEnrollment) SyncActionButton("같은 요청 다시 보내기") { model.retryEnrollment() }
            if (actions.canAdvanceBootstrap) SyncActionButton("합성 스냅샷 한 페이지 받기") { model.advanceBootstrap() }
        }

        if (actions.canRequestDisconnect) {
            Text(
                "연결 해제",
                style = KakaoText.caption,
                color = colors.textSecondary,
                modifier = Modifier.padding(top = 10.dp).clickable { model.requestDisconnect() },
            )
        }

        if (confirmingDisconnect) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 10.dp)
                    .background(colors.surface, RoundedCornerShape(10.dp))
                    .padding(12.dp),
            ) {
                Text("연결을 해제하시겠습니까?", style = KakaoText.listName, color = colors.textPrimary)
                Text(
                    "이 버전에서는 확인만 제공하며 저장된 키나 원격 자료를 지우지 않습니다.",
                    style = KakaoText.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(top = 4.dp),
                )
                Text(
                    "닫기",
                    style = KakaoText.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(top = 8.dp).clickable { model.dismissDisconnect() },
                )
            }
        }

        // The host only. A full URL could carry a path or query, and this is the
        // one thing about the endpoint the screen ever shows.
        Text(
            "연결 대상: ${environment.displayHost}",
            style = KakaoText.listTime,
            color = colors.textTertiary,
            modifier = Modifier.padding(top = 10.dp),
        )
    }
}

/** Runs the blocking coordinators off the main thread. */
@Composable
private fun SyncActionButton(title: String, work: () -> Unit) {
    val colors = KakaoTheme.colors
    val scope = rememberCoroutineScope()
    Box(
        Modifier
            .background(colors.bubbleMine, RoundedCornerShape(8.dp))
            .clickable { scope.launch { withContext(Dispatchers.IO) { work() } } }
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        Text(title, style = KakaoText.caption, color = colors.bubbleMineText)
    }
}

private fun buildModel(context: Context, environment: SyncSyntheticEnvironment): SyncOnboardingModel? =
    runCatching {
        val directory = File(context.filesDir, "sync")
        val replica = SyncReplicaStore(File(directory, "replica.json"))
        val secrets = SyncSecretStore(context)
        val onboarding = SyncOnboardingCoordinator(
            baseUrl = environment.base_url,
            vault = KeystoreSyncSecretVault(secrets),
            connectionStore = SyncConnectionStateStore(File(directory, "connection.json")),
            journal = SyncEnrollmentJournal(File(directory, "enrollment.bin")),
            transport = OkHttpSyncTransport(),
            words = SyncRecoveryMnemonic.bundledWords(context),
        )
        val client = SyncWorkerClient(
            environment.base_url,
            // Read per request, not captured here. This screen is built while
            // nothing is stored yet, so a token taken now would stay empty for
            // the rest of the session and every read would be refused until
            // the app restarted.
            { (secrets.load() as? SyncSecretLoadResult.Available)?.secrets?.deviceToken },
            OkHttpSyncTransport(),
        )
        SyncOnboardingModel(
            onboarding = onboarding,
            pull = SyncPullCoordinator(client, replica, File(directory, "pull.json")),
            replica = replica,
            spaceId = if (BuildConfig.TABLET_MENTOR) "TABLET_SPACE" else "PHONE_SPACE",
            platform = if (BuildConfig.TABLET_MENTOR) "android_tablet" else "android_phone",
            identity = {
                SyncOnboardingIdentity(environment.account_id, environment.device_id, environment.enrollment_id)
            },
        )
    }.getOrNull()

private fun statusTitle(state: SyncOnboardingUiState): String = when (state) {
    is SyncOnboardingUiState.Disconnected -> "연결 안 됨"
    is SyncOnboardingUiState.Preparing -> "연결 준비 중"
    is SyncOnboardingUiState.AwaitingPhraseConfirmation -> "복구 문구 확인 필요"
    is SyncOnboardingUiState.Enrolling -> "등록 요청 중"
    is SyncOnboardingUiState.ConnectedSyncOff -> "연결됨 · 동기화 꺼짐"
    is SyncOnboardingUiState.Bootstrapping -> "합성 스냅샷 받는 중"
    is SyncOnboardingUiState.ReplicaReady -> "합성 자료 준비됨"
    is SyncOnboardingUiState.RelinkRequired -> "재연결 필요"
    is SyncOnboardingUiState.RetryableError -> "다시 시도할 수 있는 오류"
}

private fun statusDetail(state: SyncOnboardingUiState): String = when (state) {
    is SyncOnboardingUiState.Disconnected -> "아직 아무것도 보내지 않았습니다."
    is SyncOnboardingUiState.Preparing -> "요청을 만들고 있습니다. 아직 보내지 않았습니다."
    is SyncOnboardingUiState.AwaitingPhraseConfirmation -> "문구를 보관하기 전에는 등록 요청을 보내지 않습니다."
    is SyncOnboardingUiState.Enrolling -> "서버 응답을 기다리는 중입니다."
    is SyncOnboardingUiState.ConnectedSyncOff -> "계정만 연결했습니다. 실제 대화 동기화는 켜지지 않았습니다."
    is SyncOnboardingUiState.Bootstrapping -> "받은 항목 ${state.appliedItems}개. 한 번에 한 페이지씩 받습니다."
    is SyncOnboardingUiState.ReplicaReady ->
        "합성 항목 ${state.entryCount}개를 별도 보관소에 두었습니다. 기존 대화는 그대로입니다."
    is SyncOnboardingUiState.RelinkRequired ->
        "저장된 키와 연결 정보가 맞지 않습니다. 새 키를 자동으로 만들지 않습니다."
    // A cause, never a value: no endpoint, token, phrase or server message.
    is SyncOnboardingUiState.RetryableError -> when (state.error) {
        SyncOnboardingUiError.PHRASE_NOT_CONFIRMED -> "문구 확인이 끝나지 않았습니다."
        SyncOnboardingUiError.ENROLLMENT_REFUSED -> "서버가 등록을 받지 않았습니다."
        SyncOnboardingUiError.ENROLLMENT_REFUSED_RETRY_PENDING ->
            "서버가 등록을 받지 않았습니다. 같은 요청을 그대로 다시 보낼 수 있습니다."
        SyncOnboardingUiError.STORAGE_FAILED -> "이 기기에 저장하지 못했습니다."
        SyncOnboardingUiError.NETWORK_FAILED -> "서버에 닿지 못했습니다."
        SyncOnboardingUiError.BOOTSTRAP_FAILED -> "받은 페이지를 적용하지 못했습니다. 같은 위치부터 다시 받습니다."
    }
}
