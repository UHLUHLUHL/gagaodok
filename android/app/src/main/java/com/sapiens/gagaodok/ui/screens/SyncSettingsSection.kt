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
import com.sapiens.gagaodok.sync.KeystoreSyncSlottedSecretVault
import com.sapiens.gagaodok.sync.SyncAccountTransitionCoordinator
import com.sapiens.gagaodok.sync.SyncAccountTransitionJournal
import com.sapiens.gagaodok.sync.SyncAccountTransitionModel
import com.sapiens.gagaodok.sync.SyncAccountTransitionUiState
import com.sapiens.gagaodok.sync.OkHttpSyncTransport
import com.sapiens.gagaodok.sync.SyncConnectionLoadResult
import com.sapiens.gagaodok.sync.SyncConnectionStateStore
import com.sapiens.gagaodok.sync.SyncDeviceListModel
import com.sapiens.gagaodok.sync.SyncDeviceListState
import com.sapiens.gagaodok.sync.SyncEnrollmentJournal
import com.sapiens.gagaodok.sync.SyncOnboardingCoordinator
import com.sapiens.gagaodok.sync.SyncOnboardingIdentity
import com.sapiens.gagaodok.sync.SyncOnboardingModel
import com.sapiens.gagaodok.sync.SyncOnboardingUiError
import com.sapiens.gagaodok.sync.SyncOnboardingUiState
import com.sapiens.gagaodok.sync.SyncPullCoordinator
import com.sapiens.gagaodok.sync.SyncRecoveryMnemonic
import com.sapiens.gagaodok.sync.SyncReplicaStore
import com.sapiens.gagaodok.data.ChatStore
import com.sapiens.gagaodok.sync.SyncShadowWriteModel
import com.sapiens.gagaodok.sync.SyncShadowWriteState
import com.sapiens.gagaodok.sync.SyncOutbox
import com.sapiens.gagaodok.sync.SyncShadowVerifyModel
import com.sapiens.gagaodok.sync.SyncShadowVerifyState
import com.sapiens.gagaodok.sync.SyncSecretLoadResult
import com.sapiens.gagaodok.sync.SyncSecretStore
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import com.sapiens.gagaodok.sync.SyncRuntimeHost
import com.sapiens.gagaodok.sync.SyncSyntheticEnvironment
import com.sapiens.gagaodok.sync.SyncTransitionFiles
import com.sapiens.gagaodok.sync.SyncTransitionAvailability
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
    val transition = remember(environment) { environment?.let { buildTransition(context) } }
    val devices = remember(environment) { environment?.let { buildDeviceList(context, it) } }
    val shadowVerify = remember(environment) { environment?.let { buildShadowVerify(context, it) } }
    val shadowWrite = remember(environment) { environment?.let { buildShadowWrite(context, it) } }

    Column(Modifier.fillMaxWidth().padding(14.dp)) {
        Text(
            "시험용 합성 계정만 연결합니다. 이 화면은 실제 대화를 읽거나 올리지 않습니다.",
            style = KakaoText.caption,
            color = colors.textSecondary,
        )
        // 지금 동기화가 실제로 무엇을 하고 있는지 한 줄로 말한다. 설정 파일이
        // 없어도 보인다. 꺼져 있는 것과 설정이 없는 것은 다른 상태다.
        Row(
            modifier = Modifier.padding(top = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(6.dp)
                    .background(
                        if (SyncRuntimeHost.status.isActive) Color(0xFF34C759)
                        else colors.textSecondary.copy(alpha = 0.5f),
                        CircleShape,
                    ),
            )
            Text(
                SyncRuntimeHost.statusLabel,
                style = KakaoText.caption,
                color = colors.textSecondary,
                modifier = Modifier.padding(start = 6.dp),
            )
        }

        if (model == null || environment == null) {
            Text(
                "합성 시험 환경이 설정되어 있지 않습니다. 설정 파일이 없으면 이 화면은 아무것도 하지 않습니다.",
                style = KakaoText.caption,
                color = colors.textTertiary,
                modifier = Modifier.padding(top = 8.dp),
            )
            return@Column
        }

        if (BuildConfig.PAIRING_TEST) {
            SyncPairingJoinerSection(environment)
            Text(
                "연결 대상: ${environment.displayHost}",
                style = KakaoText.listTime,
                color = colors.textTertiary,
                modifier = Modifier.padding(top = 10.dp),
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

        transition?.let {
            if (it.availability == SyncTransitionAvailability.NO_ACTIVE_ACCOUNT) {
                SyncPairingJoinerSection(environment)
            } else {
                SyncAccountTransitionSection(environment, it) { model.refresh() }
            }
        }

        devices?.let { SyncDeviceListSection(it) }
        shadowVerify?.let { SyncShadowVerifySection(it) }
        shadowWrite?.let { SyncShadowWriteSection(it, REVERSE_TEST_ROOM_TITLE) }

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

@Composable
private fun SyncDeviceListSection(model: SyncDeviceListModel) {
    val state by model.state.collectAsState()
    val pending by model.pendingRevoke.collectAsState()
    val revokeFailed by model.revokeFailed.collectAsState()
    val colors = KakaoTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(top = 12.dp)
            .background(colors.surface, RoundedCornerShape(10.dp)).padding(12.dp),
    ) {
        Text("연결된 기기", style = KakaoText.listName, color = colors.textPrimary)
        when (val current = state) {
            SyncDeviceListState.Idle -> {
                Text("버튼을 누르면 이 계정에 연결된 기기만 확인합니다.", style = KakaoText.caption, color = colors.textSecondary)
                SyncActionButton("연결된 기기 보기") { model.load() }
            }
            SyncDeviceListState.Loading ->
                Text("기기 목록을 확인하고 있습니다.", style = KakaoText.caption, color = colors.textSecondary)
            SyncDeviceListState.Failed -> {
                Text("기기 목록을 가져오지 못했습니다. 비밀값은 표시하지 않았습니다.", style = KakaoText.caption, color = colors.textSecondary)
                SyncActionButton("다시 시도") { model.load() }
            }
            is SyncDeviceListState.Loaded -> {
                if (current.devices.isEmpty()) Text("현재 표시할 기기가 없습니다.", style = KakaoText.caption, color = colors.textSecondary)
                if (revokeFailed) {
                    Text("기기를 빼지 못했습니다. 목록은 그대로입니다.", style = KakaoText.caption, color = colors.textSecondary)
                }
                current.devices.forEach { device ->
                    Text(device.title + if (device.isCurrent) " · 현재 기기" else "", style = KakaoText.listPreview, color = colors.textPrimary)
                    Text("연결: ${device.linkedAt}", style = KakaoText.listTime, color = colors.textTertiary)
                    if (model.canRevoke(device) && pending == null) {
                        SyncActionButton("빼기") { model.requestRevoke(device) }
                    }
                }
                pending?.let {
                    Text(
                        "${it.title}을(를) 이 계정에서 뺍니다. 그 기기는 더 이상 동기화하지 못하고, " +
                            "다시 쓰려면 QR 합류를 처음부터 다시 해야 합니다. 이 기기의 대화는 그대로입니다.",
                        style = KakaoText.caption,
                        color = colors.textSecondary,
                    )
                    SyncActionButton("빼기 확인") { model.confirmRevoke() }
                    SyncActionButton("취소") { model.cancelRevoke() }
                }
                SyncActionButton("새로고침") { model.load() }
            }
        }
    }
}

private data class SyncTransitionUI(
    val model: SyncAccountTransitionModel,
    val coordinator: SyncAccountTransitionCoordinator,
    val availability: SyncTransitionAvailability,
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SyncAccountTransitionSection(
    environment: SyncSyntheticEnvironment,
    transition: SyncTransitionUI,
    onChanged: () -> Unit,
) {
    val state by transition.model.state.collectAsState()
    val colors = KakaoTheme.colors
    val scope = rememberCoroutineScope()
    LaunchedEffect(transition) { withContext(Dispatchers.IO) { transition.model.refresh() } }

    Column(
        Modifier.fillMaxWidth().padding(top = 12.dp)
            .background(colors.surface, RoundedCornerShape(10.dp)).padding(12.dp),
    ) {
        Text("동기화 계정 관리", style = KakaoText.listName, color = colors.textPrimary)
        Text(
            when (state) {
                SyncAccountTransitionUiState.CONFIRMING_JOIN ->
                    "새 계정 확인이 끝날 때까지 현재 연결을 유지합니다. 완료 뒤에도 동기화는 꺼져 있습니다."
                SyncAccountTransitionUiState.CONFIRMING_UNLINK ->
                    "로컬 대화는 유지하고 이 기기의 동기화 키와 shadow 자료만 제거합니다. 다른 기기와 원격 계정은 삭제하지 않습니다."
                SyncAccountTransitionUiState.BLOCKED ->
                    "동기화가 켜져 있거나 미전송 변경이 남아 있어 지금은 계정을 바꿀 수 없습니다."
                SyncAccountTransitionUiState.UNLINKED -> "이 기기의 연결을 해제했습니다. 로컬 대화는 그대로입니다."
                SyncAccountTransitionUiState.ERROR -> "변경을 완료하지 못했습니다. 기존 연결을 유지했습니다."
                else -> "로컬 대화를 보존한 채 다른 계정에 합류하거나 이 기기의 연결만 해제할 수 있습니다."
            },
            style = KakaoText.caption, color = colors.textSecondary, modifier = Modifier.padding(top = 4.dp),
        )

        FlowRow(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            val actions = transition.model.actions
            if (actions.canRequestJoin) SyncActionButton("다른 계정에 이 기기 합류") { transition.model.requestJoin() }
            if (actions.canConfirmJoin) SyncActionButton("계속") { transition.model.confirmJoin() }
            if (actions.canRequestUnlink) SyncActionButton("이 기기 연결 해제") { transition.model.requestUnlink() }
            if (actions.canConfirmUnlink) SyncActionButton("연결 해제 확인") {
                scope.launch {
                    withContext(Dispatchers.IO) { transition.model.confirmUnlink() }
                    onChanged()
                }
            }
            if (actions.canDismiss) SyncActionButton("취소") { transition.model.dismiss() }
        }

        if (transition.model.actions.canStartScanner) {
            SyncPairingJoinerSection(environment, transition.coordinator)
        }
    }
}

private fun buildTransition(context: Context): SyncTransitionUI? = runCatching {
    val directory = File(context.filesDir, "sync")
    val coordinator = SyncAccountTransitionCoordinator(
        vault = KeystoreSyncSlottedSecretVault(SyncSecretStore(context)),
        connectionStore = SyncConnectionStateStore(File(directory, "connection.json")),
        files = SyncTransitionFiles(directory),
        journal = SyncAccountTransitionJournal(File(directory, "transition.json")),
        outbox = com.sapiens.gagaodok.sync.SyncOutbox(File(directory, "outbox.bin")),
    )
    coordinator.recoverIfNeeded()
    val availability = coordinator.availability()
    SyncTransitionUI(SyncAccountTransitionModel(coordinator), coordinator, availability)
}.getOrNull()

private fun buildDeviceList(context: Context, environment: SyncSyntheticEnvironment): SyncDeviceListModel? = runCatching {
    val secrets = SyncSecretStore(context)
    SyncDeviceListModel(
        SyncWorkerClient(
            environment.base_url,
            { (secrets.load() as? SyncSecretLoadResult.Available)?.secrets?.deviceToken },
            OkHttpSyncTransport(),
        ),
    )
}.getOrNull()

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

/**
 * Whether this device can read what the Mac wrote.
 *
 * Counts and one digest, never a line of the conversation. The digest is built
 * from bubble identity and order alone, so comparing it with the Mac's is a
 * complete answer to "did the same bubbles arrive in the same order" that
 * neither screen has to spell out to give.
 */
@Composable
private fun SyncShadowVerifySection(model: SyncShadowVerifyModel) {
    val state by model.state.collectAsState()
    val colors = KakaoTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(top = 12.dp)
            .background(colors.surface, RoundedCornerShape(10.dp)).padding(12.dp),
    ) {
        Text("시험방 받아 확인", style = KakaoText.listName, color = colors.textPrimary)
        when (val current = state) {
            SyncShadowVerifyState.Idle -> {
                Text(
                    "Mac이 올린 시험방을 받아 이 기기 키로 실제로 풀 수 있는지 확인합니다. 대화 내용은 화면에 표시하지 않습니다.",
                    style = KakaoText.caption, color = colors.textSecondary,
                )
                SyncActionButton("받아서 확인") { model.run() }
            }
            SyncShadowVerifyState.Running ->
                Text("받아서 확인하는 중입니다.", style = KakaoText.caption, color = colors.textSecondary)
            is SyncShadowVerifyState.Failed -> {
                Text(current.reason, style = KakaoText.caption, color = colors.textSecondary)
                SyncActionButton("다시 시도") { model.run() }
            }
            is SyncShadowVerifyState.Finished -> {
                val result = current.result
                Text(
                    if (result.allDecrypted) "받은 말풍선을 모두 풀었습니다."
                    else "풀지 못한 말풍선이 있습니다.",
                    style = KakaoText.caption, color = colors.textSecondary,
                )
                Text("turn ${result.turnCount} · 말풍선 ${result.bubbleCount}", style = KakaoText.listPreview, color = colors.textPrimary)
                Text("복호화 성공 ${result.decryptedCount} / ${result.bubbleCount}", style = KakaoText.listPreview, color = colors.textPrimary)
                // Compare this with the Mac's. Identity and order only.
                Text("내용 hash ${result.contentHash.take(16)}…", style = KakaoText.listTime, color = colors.textTertiary)
                // Shown only while the shadow is being brought up: it is what
                // tells a wrong account apart from a wrong key.
                Text(result.diagnostic, style = KakaoText.listTime, color = colors.textTertiary)
                SyncActionButton("다시 확인") { model.run() }
            }
        }
    }
}

/**
 * The one room Phase 3 is allowed to touch, matching the Mac.
 *
 * Hard-coded rather than picked in the UI for the same reason it is on the
 * Mac: a picker over every room is one misclick away from pulling a
 * conversation nobody agreed to copy.
 */
private const val DESIGNATED_SHADOW_ROOM = "90B3EE60-2244-4838-9C1E-10A27295F6EB"

private fun buildShadowVerify(
    context: Context,
    environment: SyncSyntheticEnvironment,
): SyncShadowVerifyModel? = runCatching {
    val directory = File(context.filesDir, "sync")
    val secrets = SyncSecretStore(context)
    val client = SyncWorkerClient(
        environment.base_url,
        { (secrets.load() as? SyncSecretLoadResult.Available)?.secrets?.deviceToken },
        OkHttpSyncTransport(),
    )
    val replica = SyncReplicaStore(File(directory, "replica.json"))
    // The account this device is actually in, which is not always the one its
    // synthetic environment file names. A device that joined by pairing keeps
    // its own pre-join account_id in that file while the account it really
    // belongs to is the host's, recorded in connection state. Scope keys are
    // derived from the account, so reading the wrong one decrypts nothing
    // while leaving identity, order and the content digest looking correct.
    val connection = SyncConnectionStateStore(File(directory, "connection.json")).load()
    val accountId = (connection as? SyncConnectionLoadResult.Available)
        ?.configuration?.accountId ?: environment.account_id
    SyncShadowVerifyModel(
        pull = SyncPullCoordinator(client, replica, File(directory, "pull.json")),
        replica = replica,
        accountId = accountId,
        roomId = DESIGNATED_SHADOW_ROOM,
        loadSecrets = { secrets.load() },
    )
}.getOrNull()

/**
 * The reverse direction: this device's own room, copied up for the Mac.
 *
 * Two presses, not one. The first names the room and counts what is in it; only
 * then does a button appear that sends anything. What is copied is stated
 * before it leaves, on the device that owns it.
 */
@Composable
private fun SyncShadowWriteSection(model: SyncShadowWriteModel, roomTitle: String) {
    val state by model.state.collectAsState()
    val colors = KakaoTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(top = 12.dp)
            .background(colors.surface, RoundedCornerShape(10.dp)).padding(12.dp),
    ) {
        Text("이 기기의 방 올리기 (단방향)", style = KakaoText.listName, color = colors.textPrimary)
        when (val current = state) {
            SyncShadowWriteState.Idle -> {
                Text(
                    "\"$roomTitle\" 방을 암호화해 올립니다. 먼저 무엇이 올라가는지 확인합니다. 원본 대화 파일은 읽기만 합니다.",
                    style = KakaoText.caption, color = colors.textSecondary,
                )
                SyncActionButton("올릴 방 확인") { model.inspect() }
            }
            is SyncShadowWriteState.Ready -> {
                val target = current.target
                Text("올릴 방: ${target.title}", style = KakaoText.listPreview, color = colors.textPrimary)
                Text("말풍선 ${target.bubbleCount}개", style = KakaoText.listPreview, color = colors.textPrimary)
                if (target.attachmentCount > 0) {
                    Text(
                        "첨부 ${target.attachmentCount}개는 이번에 올리지 않습니다.",
                        style = KakaoText.caption, color = colors.textSecondary,
                    )
                }
                SyncActionButton("확인하고 올리기") { model.run() }
            }
            SyncShadowWriteState.Running ->
                Text("올리는 중입니다.", style = KakaoText.caption, color = colors.textSecondary)
            is SyncShadowWriteState.Failed -> {
                Text(current.reason, style = KakaoText.caption, color = colors.textSecondary)
                SyncActionButton("다시 확인") { model.inspect() }
            }
            is SyncShadowWriteState.Finished -> {
                val result = current.result
                Text("올렸습니다.", style = KakaoText.caption, color = colors.textSecondary)
                Text(
                    "turn ${result.manifest.turnCount} · 말풍선 ${result.manifest.bubbleCount}",
                    style = KakaoText.listPreview, color = colors.textPrimary,
                )
                Text("올린 operation ${result.uploadedOperations}", style = KakaoText.listPreview, color = colors.textPrimary)
                if (result.skippedAttachments > 0) {
                    Text("복사 안 한 첨부 ${result.skippedAttachments}", style = KakaoText.listTime, color = colors.textTertiary)
                }
                // Compare with the Mac's. Identity and order only.
                Text("내용 hash ${result.manifest.contentHash.take(16)}…", style = KakaoText.listTime, color = colors.textTertiary)
                Text("방 ${result.manifest.roomId.take(8)}…", style = KakaoText.listTime, color = colors.textTertiary)
            }
        }
    }
}

/** The room the user made for this pass, named rather than identified by id. */
private const val REVERSE_TEST_ROOM_TITLE = "역방향테스트"

private fun buildShadowWrite(
    context: Context,
    environment: SyncSyntheticEnvironment,
): SyncShadowWriteModel? = runCatching {
    val directory = File(context.filesDir, "sync")
    val secrets = SyncSecretStore(context)
    val store = ChatStore.get(context)
    val connection = SyncConnectionStateStore(File(directory, "connection.json")).load()
    val configuration = (connection as? SyncConnectionLoadResult.Available)?.configuration
    SyncShadowWriteModel(
        rooms = { store.rooms.value },
        // Read-only, and the active worldline's file for a group room, which is
        // the same conversation the room screen shows.
        messages = { room -> store.loadMessages(room.id) },
        roomTitle = REVERSE_TEST_ROOM_TITLE,
        // The joined account, not the pre-join one the environment file names.
        accountId = configuration?.accountId ?: environment.account_id,
        deviceId = configuration?.deviceId ?: environment.device_id,
        spaceId = if (BuildConfig.TABLET_MENTOR) "TABLET_SPACE" else "PHONE_SPACE",
        client = SyncWorkerClient(
            environment.base_url,
            { (secrets.load() as? SyncSecretLoadResult.Available)?.secrets?.deviceToken },
            OkHttpSyncTransport(),
        ),
        outbox = SyncOutbox(File(directory, "shadow-outbox.bin")),
        loadSecrets = { secrets.load() },
    )
}.getOrNull()
