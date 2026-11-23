package com.gammagamma.grana.scanner

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.util.Log
import com.google.mlkit.genai.agent.Agent
import com.google.mlkit.genai.agent.AgentEvent
import com.google.mlkit.genai.agent.AgentRunner
import com.google.mlkit.genai.agent.AgentSession
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Content
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

data class AiExtractedMenu(
    val inferredCurrency: String?,
    val inferenceReason: String?,
    val items: List<Map<String, Any?>>,
)

data class NativeAgentReply(
    val handled: Boolean,
    val responseText: String,
    val invokedTools: List<String>,
)

/**
 * Wraps Android AICore Gemini Nano 4 multimodal Prompt API and ML Kit Agentic API
 * (`AgentRunner` + AppFunctions) with safe runtime capability checks.
 */
class GeminiNanoPriceAgent(private val context: Context) {
    companion object {
        private const val TAG = "GeminiNanoPriceAgent"
        private const val SESSION_ID = "grana_menu_scan_session"
    }

    private var generativeModel: GenerativeModel? = null
    private var agentRunner: AgentRunner? = null
    private var activeSession: AgentSession? = null

    private fun getOrCreateModel(): GenerativeModel? {
        if (Build.VERSION.SDK_INT < 34) return null
        if (generativeModel != null) return generativeModel
        return try {
            Generation.getClient().also { generativeModel = it }
        } catch (t: Throwable) {
            Log.w(TAG, "AICore Generation.getClient() unavailable: ${t.message}")
            null
        }
    }

    private fun getOrCreateRunner(): AgentRunner? {
        if (Build.VERSION.SDK_INT < 34) return null
        if (agentRunner != null) return agentRunner
        return try {
            val agent = Agent.builder()
                .setName("GranaPriceAssistant")
                .setInstructions(
                    "You are Grana's on-device currency and menu assistant. " +
                        "Always use convert_currency, calculate_tip_and_split, and sum_menu_prices " +
                        "for exact math instead of guessing conversions. Keep answers concise (1-3 lines).",
                )
                .enableAppFunctions(true)
                .build()
            AgentRunner(context, agent).also { agentRunner = it }
        } catch (t: Throwable) {
            Log.w(TAG, "ML Kit AgentRunner initialization unavailable: ${t.message}")
            null
        }
    }

    suspend fun checkAvailabilityStatus(): String {
        val model = getOrCreateModel() ?: return "unavailable"
        return try {
            when (model.checkStatus()) {
                FeatureStatus.AVAILABLE -> "available"
                FeatureStatus.DOWNLOADABLE -> "downloadable"
                FeatureStatus.DOWNLOADING -> "downloading"
                else -> "unavailable"
            }
        } catch (t: Throwable) {
            Log.w(TAG, "checkStatus failed: ${t.message}")
            "unavailable"
        }
    }

    suspend fun downloadModelIfNeeded(): Boolean {
        val model = getOrCreateModel() ?: return false
        return try {
            when (model.checkStatus()) {
                FeatureStatus.AVAILABLE -> true
                FeatureStatus.DOWNLOADABLE, FeatureStatus.DOWNLOADING -> {
                    var completed = false
                    model.download().collect { status ->
                        when (status) {
                            is DownloadStatus.DownloadStarted ->
                                Log.d(TAG, "Gemini Nano download started")
                            is DownloadStatus.DownloadProgress ->
                                Log.d(TAG, "Gemini Nano downloaded ${status.totalBytesDownloaded} bytes")
                            DownloadStatus.DownloadCompleted -> {
                                Log.d(TAG, "Gemini Nano download complete")
                                completed = true
                            }
                            is DownloadStatus.DownloadFailed ->
                                Log.w(TAG, "Gemini Nano download failed: ${status.e.message}")
                        }
                    }
                    completed
                }
                else -> false
            }
        } catch (t: Throwable) {
            Log.w(TAG, "downloadModelIfNeeded error: ${t.message}")
            false
        }
    }

    suspend fun analyzeMenuBitmap(
        bitmap: Bitmap,
        ocrHintText: String,
        selectedCurrencies: List<String>,
        lockedSourceCurrency: String?,
        locationCurrency: String? = null,
    ): AiExtractedMenu? {
        val model = getOrCreateModel() ?: return null
        try {
            if (model.checkStatus() != FeatureStatus.AVAILABLE) return null
        } catch (_: Throwable) {
            return null
        }

        val currencyHint = when {
            !lockedSourceCurrency.isNullOrBlank() ->
                "The user manually selected $lockedSourceCurrency as the source currency. Use $lockedSourceCurrency for all prices."
            !locationCurrency.isNullOrBlank() ->
                "The user's current physical location currency is $locationCurrency. Use $locationCurrency unless an explicit unambiguous currency symbol or ISO code (such as US$, RD$, €, £, USD, EUR) clearly specifies another currency."
            else ->
                "Infer the 3-letter ISO currency code from explicit symbols or ISO codes. User's favorite currencies: ${selectedCurrencies.joinToString(", ")}."
        }

        val prompt = """
Extract ONLY numeric prices and their 3-letter ISO currency code from this image.
$currencyHint
OCR text detected:
$ocrHintText

Rules:
1. Extract ONLY numeric prices. Do NOT transcribe, describe, or translate dish names, product names, or any surrounding text.
2. Ignore non-prices (calories, weights/ml, percentages, phone numbers, dates, years, street numbers, quantities).
3. Convert regional thousands/decimals and shorthand to exact numeric values in normalizedAmount. A dot or comma followed by 3 digits (such as "${'$'}1.350", "${'$'}1.300", "28.000", "1,350") is a thousands separator (1350.0, 1300.0, 28000.0), NOT a decimal (except for 3-decimal currencies like KWD/BHD/OMR/JOD). "18k" -> 18000.0, "12,50 €" -> 12.5.
4. Return ONLY valid JSON matching this exact structure, with no markdown fences:
{"inferredCurrency":"DOP","items":[{"rawText":"RD$450","normalizedAmount":450.0,"currencyCode":"DOP","isShorthandMultiplied":false}]}
        """.trimIndent()

        return try {
            val request = generateContentRequest(ImagePart(bitmap), TextPart(prompt)) {
                temperature = 0.0f
                maxOutputTokens = 1024
            }
            val response = model.generateContent(request)
            val rawText = response.candidates.firstOrNull()?.text ?: return null
            parseExtractedJson(rawText)
        } catch (e: GenAiException) {
            Log.w(TAG, "Gemini Nano multimodal inference GenAiException (${e.errorCode}): ${e.message}")
            null
        } catch (t: Throwable) {
            Log.w(TAG, "Gemini Nano multimodal inference error: ${t.message}")
            null
        }
    }

    suspend fun askAgent(
        userPrompt: String,
        sourceCurrency: String,
        selectedCurrencies: List<String>,
        ratesBySymbol: Map<String, Double>,
        scannedItemsSummary: String,
    ): NativeAgentReply {
        val model = getOrCreateModel()
            ?: return NativeAgentReply(false, "", emptyList())
        try {
            if (model.checkStatus() != FeatureStatus.AVAILABLE) {
                return NativeAgentReply(false, "", emptyList())
            }
        } catch (_: Throwable) {
            return NativeAgentReply(false, "", emptyList())
        }

        GranaAgentRateStore.updateRates(ratesBySymbol)

        val runner = getOrCreateRunner()
            ?: return NativeAgentReply(false, "", emptyList())

        return try {
            val session = activeSession ?: runner.getOrCreateSession(SESSION_ID).also {
                activeSession = it
            }

            val contextualPrompt = """
Scanned items ($sourceCurrency):
$scannedItemsSummary
Target currencies: ${selectedCurrencies.joinToString(", ")}

User request: $userPrompt
            """.trimIndent()

            val content = Content.builder().text(contextualPrompt).build()
            val invokedTools = mutableListOf<String>()
            val responseBuilder = StringBuilder()

            session.runAsync(content).collect { event ->
                when (event) {
                    is AgentEvent.FunctionCall -> {
                        invokedTools.add(event.name)
                    }
                    is AgentEvent.FunctionResponse -> {
                        Log.d(TAG, "Tool ${event.name} completed")
                    }
                    is AgentEvent.TextMessage -> {
                        responseBuilder.append(event.text)
                    }
                    else -> {}
                }
            }

            val finalReply = responseBuilder.toString().trim()
            NativeAgentReply(
                handled = finalReply.isNotEmpty(),
                responseText = finalReply,
                invokedTools = invokedTools,
            )
        } catch (e: GenAiException) {
            Log.w(TAG, "AgentRunner GenAiException (${e.errorCode}): ${e.message}")
            NativeAgentReply(false, "", emptyList())
        } catch (t: Throwable) {
            Log.w(TAG, "AgentRunner execution error: ${t.message}")
            NativeAgentReply(false, "", emptyList())
        }
    }

    fun closeSession() {
        try {
            activeSession?.close()
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    agentRunner?.deleteSession(SESSION_ID)
                } catch (_: Throwable) {
                }
            }
        } catch (_: Throwable) {
        } finally {
            activeSession = null
        }
    }

    fun releaseAll() {
        closeSession()
        try {
            generativeModel?.close()
        } catch (_: Throwable) {
        } finally {
            generativeModel = null
        }
    }

    private fun parseExtractedJson(raw: String): AiExtractedMenu? {
        val cleaned = raw
            .trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        val startIdx = cleaned.indexOf('{')
        val endIdx = cleaned.lastIndexOf('}')
        if (startIdx < 0 || endIdx <= startIdx) return null

        val jsonObj = JSONObject(cleaned.substring(startIdx, endIdx + 1))
        val inferredCurrency = jsonObj.optString("inferredCurrency", "").takeIf { it.isNotBlank() }
        val inferenceReason = jsonObj.optString("inferenceReason", "").takeIf { it.isNotBlank() }
        val itemsArr: JSONArray = jsonObj.optJSONArray("items") ?: JSONArray()

        val items = mutableListOf<Map<String, Any?>>()
        for (i in 0 until itemsArr.length()) {
            val itemObj = itemsArr.optJSONObject(i) ?: continue
            val amount = itemObj.optDouble("normalizedAmount", Double.NaN)
            if (amount.isNaN() || amount <= 0.0) continue

            items.add(
                mapOf(
                    "itemLabel" to null,
                    "rawText" to itemObj.optString("rawText", amount.toString()),
                    "normalizedAmount" to amount,
                    "currencyCode" to itemObj.optString("currencyCode", "").takeIf { it.isNotBlank() },
                    "isShorthandMultiplied" to itemObj.optBoolean("isShorthandMultiplied", false),
                ),
            )
        }

        return AiExtractedMenu(
            inferredCurrency = inferredCurrency,
            inferenceReason = inferenceReason,
            items = items,
        )
    }
}
