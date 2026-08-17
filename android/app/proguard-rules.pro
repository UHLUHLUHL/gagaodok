# kotlinx.serialization 은 생성된 직렬화기를 리플렉션으로 찾습니다.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.sapiens.gagaodok.**$$serializer { *; }
-keepclassmembers class com.sapiens.gagaodok.** {
    *** Companion;
}
-keepclasseswithmembers class com.sapiens.gagaodok.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**

# API 키를 암호화하는 Tink는 컴파일 시점에만 쓰는 검사 애너테이션을 참조합니다.
# 그 애너테이션은 앱에 들어오지 않으므로 없다고 경고할 뿐, 동작에는 영향이 없습니다.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**

# 수식 웹뷰에서 자바스크립트가 부르는 다리
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
