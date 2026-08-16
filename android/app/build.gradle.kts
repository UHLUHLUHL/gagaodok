plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.sapiens.gagaodok"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.sapiens.gagaodok"
        // 적응형 아이콘이 26부터입니다. 실사용 기기 대부분을 덮습니다.
        minSdk = 26
        targetSdk = 35
        // 1.1: 원조 실기기 캡처를 실측해 색·도형·치수를 맞춘 판입니다.
        // 1.2: 이웃한 요소끼리 견줘 어긋난 크기를 바로잡았습니다(입력바 단추, 탭 아이콘 등).
        // 1.3: 목록 시각 위치, 길게 누르기 메뉴를 원조 카드로, 메시지 수정 바를 새로 만들었습니다.
        // 1.4: 입력창 곡률, 프로필 화면, 메뉴 카드 통일, 말투 편집 손질, 요금 장부의 빈 곳을 메웠습니다.
        // 1.5: 챗봇 모드 사고량을 낮추고, 사진을 타일 기준으로 줄여 보냅니다.
        versionCode = 6
        versionName = "1.5"
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
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
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
