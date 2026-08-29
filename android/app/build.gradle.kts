plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.sapiens.gagaodok"
    compileSdk = 35

    flavorDimensions += "device"
    productFlavors {
        create("phone") {
            dimension = "device"
            applicationId = "com.sapiens.gagaodok"
            versionCode = 13
            versionName = "1.9-phone"
            buildConfigField("boolean", "TABLET_MENTOR", "false")
        }
        create("tabletMentor") {
            dimension = "device"
            applicationId = "com.sapiens.gagaodok.tabletmentor"
            versionCode = 1
            versionName = "2.0-tablet-mentor"
            buildConfigField("boolean", "TABLET_MENTOR", "true")
        }
    }

    defaultConfig {
        // 적응형 아이콘이 26부터입니다. 실사용 기기 대부분을 덮습니다.
        minSdk = 26
        targetSdk = 35
        // 1.1: 원조 실기기 캡처를 실측해 색·도형·치수를 맞춘 판입니다.
        // 1.2: 이웃한 요소끼리 견줘 어긋난 크기를 바로잡았습니다(입력바 단추, 탭 아이콘 등).
        // 1.3: 목록 시각 위치, 길게 누르기 메뉴를 원조 카드로, 메시지 수정 바를 새로 만들었습니다.
        // 1.4: 입력창 곡률, 프로필 화면, 메뉴 카드 통일, 말투 편집 손질, 요금 장부의 빈 곳을 메웠습니다.
        // 1.5: 챗봇 모드 사고량을 낮추고, 사진을 타일 기준으로 줄여 보냅니다.
        // 1.6: 안 쓸 캐시를 안 만들고, 키 저장소가 안 죽고, 요약 지침이 모드를 따릅니다.
        // 1.7: 개인·세계선 호감도, 자연스러운 단톡 응답 일정, 반응 칩과 하트 모션을 더했습니다.
        // 1.7.1: 단톡 말풍선을 스트리밍 중에 바로 재생하고, 입력 표시를 캐릭터 한 명으로
        //        모았습니다. 하트 패널의 머티리얼 물결을 걷어냈습니다.
        // 1.7.2: 응답 시간을 첫 글자까지와 그 뒤로 나눠 재고, 사고 토큰을 따로 셉니다.
        //        추측한 화자 이름은 3초까지만 보여주고, 화자가 확정되면 최소 0.6초는
        //        입력 표시를 보여줍니다.
        // 1.7.3: 대화방에 들어갈 때 화면이 멈추던 것을 고쳤습니다. 목록 상태 하나를 전환
        //        중인 두 화면이 나눠 쓰면서 측정이 끝나지 않던 문제입니다.
        // 1.8: 호감도가 왜 변했는지를 카드에 보여줍니다. 변화가 있는 턴에만 카드가 스스로
        //      펼쳐지고 4초 뒤 접힙니다. 사고량과 압축 임계값도 함께 손댔다가, 응답이
        //      느린 원인이 아님을 측정으로 확인하고 둘 다 되돌렸습니다(사고 low, 150턴).
        // 1.9: 머티리얼 물결을 앱 전체에서 걷어내고, 호감도 카드를 유리 재질로 바꿨습니다.
    }

    buildTypes {
        release {
            // 리소스 축소는 코드 축소를 함께 켜야 합니다. KaTeX 자산은 assets라 축소 대상이 아닙니다.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // 서명 설정이 없으면 릴리스 APK가 서명되지 않아 설치할 수 없습니다.
            // 키 저장소가 있으면 그것으로, 없으면 디버그 키로 서명해 어느 경우에도 설치되게 합니다.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf(
            // 길게 누르기(combinedClickable)는 아직 실험 표시가 붙어 있지만
            // 모바일에서 맥 판의 오른쪽 클릭 메뉴를 대신할 방법이 이것뿐입니다.
            "-opt-in=androidx.compose.foundation.ExperimentalFoundationApi",
            "-opt-in=androidx.compose.material3.ExperimentalMaterial3Api"
        )
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    sourceSets.getByName("main").assets.srcDir("../../Sources/KakaoSapiens/Resources/sync")
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.coil.compose)

    debugImplementation(libs.androidx.ui.tooling)
    testImplementation(libs.junit)
}
