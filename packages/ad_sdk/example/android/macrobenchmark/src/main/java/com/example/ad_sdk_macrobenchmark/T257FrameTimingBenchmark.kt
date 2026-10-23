package com.example.ad_sdk_macrobenchmark

import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class T257FrameTimingBenchmark {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    @Test
    fun loadingScroll() = runScenario("loading")

    @Test
    fun realAdMobScroll() = runScenario("real")

    private fun runScenario(scenario: String) {
        benchmarkRule.measureRepeated(
            packageName = TARGET_PACKAGE,
            metrics = listOf(FrameTimingMetric()),
            iterations = 3,
            compilationMode = CompilationMode.None(),
            setupBlock = {
                killProcess()
                pressHome()
                startActivityAndWait(
                    InstrumentationRegistry.getInstrumentation().context.packageManager
                        .getLaunchIntentForPackage(TARGET_PACKAGE)!!
                        .putExtra("t257Macrobenchmark", true)
                        .putExtra("t257Scenario", scenario)
                        .putExtra("t257AutoStart", true),
                )
                check(
                    device.wait(
                        Until.hasObject(By.descContains("t267Ready=true")),
                        30_000,
                    ),
                ) { "T257 benchmark status did not appear" }
                if (scenario == "real") {
                    check(
                        device.wait(
                            Until.hasObject(By.descContains("bannerReady=true")),
                            50_000,
                        ),
                    ) { "AdMob banner did not report ready" }
                }
            },
            measureBlock = {
                check(
                    device.wait(
                        Until.hasObject(By.descContains("benchmarkComplete=true")),
                        30_000,
                    ),
                ) { "T267 scroll did not complete" }
            },
        )
    }

    private companion object {
        const val TARGET_PACKAGE = "com.roy.admobwrapper.benchmark"
    }
}
