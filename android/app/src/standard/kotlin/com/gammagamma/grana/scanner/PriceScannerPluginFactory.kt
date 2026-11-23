package com.gammagamma.grana.scanner

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.media.ExifInterface
import android.os.Build
import android.os.CancellationSignal
import android.telephony.TelephonyManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.lang.ref.WeakReference
import java.util.Currency
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max

object PriceScannerPluginFactory {
    private const val CHANNEL_NAME = "com.gammagamma.grana/price_scanner"
    internal const val LOCATION_PERMISSION_REQUEST_CODE = 42817

    private var activeHandler: StandardPriceScannerHandler? = null

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val handler = StandardPriceScannerHandler(
            context = activity.applicationContext,
            activityRef = WeakReference(activity),
        )
        activeHandler = handler
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler(handler)
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != LOCATION_PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        activeHandler?.completeLocationPermissionRequest(granted)
        return true
    }
}

private class StandardPriceScannerHandler(
    private val context: Context,
    private val activityRef: WeakReference<Activity>,
) : MethodChannel.MethodCallHandler {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val latinRecognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private val chineseRecognizer by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }
    private val koreanRecognizer by lazy {
        TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build())
    }
    private val geminiNanoAgent = GeminiNanoPriceAgent(context)

    @Volatile
    private var pendingLocationPermission: CompletableDeferred<Boolean>? = null

    fun completeLocationPermissionRequest(granted: Boolean) {
        pendingLocationPermission?.complete(granted)
        pendingLocationPermission = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> scope.launch {
                val llmStatus = geminiNanoAgent.checkAvailabilityStatus()
                val activeTier = if (llmStatus == "available") "geminiNano4" else "onDeviceOcr"
                result.success(
                    mapOf(
                        "isSupported" to true,
                        "activeTier" to activeTier,
                        "llmStatus" to llmStatus,
                    ),
                )
            }

            "detectLocationCurrency" -> scope.launch {
                try {
                    val requestPermission = call.argument<Boolean>("requestPermission") ?: false
                    if (requestPermission && !hasLocationPermission()) {
                        requestCoarseLocationPermission()
                    }
                    val detected = withContext(Dispatchers.IO) {
                        resolveLocationCurrency()
                    }
                    result.success(detected)
                } catch (_: Throwable) {
                    result.success(emptyMap<String, Any?>())
                }
            }

            "downloadModel" -> scope.launch {
                val downloaded = geminiNanoAgent.downloadModelIfNeeded()
                result.success(downloaded)
            }

            "recognizeLiveFrame" -> scope.launch {
                try {
                    val bytes = call.argument<ByteArray>("bytes")
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    val rotation = call.argument<Int>("rotationDegrees") ?: 0
                    val format = call.argument<String>("imageFormat") ?: "nv21"

                    if (bytes == null || width <= 0 || height <= 0) {
                        result.success(emptyMap<String, Any>())
                        return@launch
                    }

                    val response = withContext(Dispatchers.Default) {
                        val inputImage = if (format == "jpeg") {
                            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                                ?: return@withContext emptyMap<String, Any>()
                            InputImage.fromBitmap(bmp, rotation)
                        } else {
                            InputImage.fromByteArray(
                                bytes,
                                width,
                                height,
                                rotation,
                                InputImage.IMAGE_FORMAT_NV21,
                            )
                        }

                        val uprightWidth = if (rotation == 90 || rotation == 270) height else width
                        val uprightHeight = if (rotation == 90 || rotation == 270) width else height

                        val visionText = latinRecognizer.process(inputImage).awaitTask()
                        val lines = extractNormalizedLines(visionText, uprightWidth, uprightHeight)

                        mapOf(
                            "lines" to lines,
                            "imageWidth" to uprightWidth,
                            "imageHeight" to uprightHeight,
                        )
                    }
                    result.success(response)
                } catch (t: Throwable) {
                    result.success(emptyMap<String, Any>())
                }
            }

            "analyzeImageSmart" -> scope.launch {
                try {
                    val imagePath = call.argument<String>("imagePath")
                    val selectedCurrencies = call.argument<List<String>>("selectedCurrencies")
                        ?: listOf("USD")
                    val lockedCurrency = call.argument<String>("lockedSourceCurrency")
                    val locationCurrency = call.argument<String>("locationCurrency")

                    if (imagePath.isNullOrBlank() || !File(imagePath).exists()) {
                        result.success(emptyMap<String, Any?>())
                        return@launch
                    }

                    val payload = withContext(Dispatchers.Default) {
                        val bitmap = loadScaledOrientedBitmap(imagePath, maxDimension = 2048)
                            ?: return@withContext emptyMap<String, Any?>()

                        val inputImage = InputImage.fromBitmap(bitmap, 0)
                        var visionText = latinRecognizer.process(inputImage).awaitTask()

                        // Supplement with Korean/CJK recognizers on still captures if sparse
                        if (visionText.textBlocks.isEmpty()) {
                            val krText = koreanRecognizer.process(inputImage).awaitTask()
                            visionText = if (krText.textBlocks.isNotEmpty()) {
                                krText
                            } else {
                                chineseRecognizer.process(inputImage).awaitTask()
                            }
                        }

                        val lines = extractNormalizedLines(
                            visionText,
                            bitmap.width,
                            bitmap.height,
                        )
                        val ocrJoined = lines.joinToString("\n") { it["text"] as String }

                        val aiBitmap = scaleBitmapForAi(bitmap, maxDimension = 1024)
                        val aiExtracted = try {
                            geminiNanoAgent.analyzeMenuBitmap(
                                bitmap = aiBitmap,
                                ocrHintText = ocrJoined,
                                selectedCurrencies = selectedCurrencies,
                                lockedSourceCurrency = lockedCurrency,
                                locationCurrency = locationCurrency,
                            )
                        } finally {
                            if (aiBitmap !== bitmap) aiBitmap.recycle()
                        }

                        mapOf<String, Any?>(
                            "lines" to lines,
                            "imageWidth" to bitmap.width,
                            "imageHeight" to bitmap.height,
                            "tierUsed" to if (aiExtracted != null) "geminiNano4" else "onDeviceOcr",
                            "inferredCurrency" to aiExtracted?.inferredCurrency,
                            "inferenceReason" to aiExtracted?.inferenceReason,
                            "aiItems" to (aiExtracted?.items ?: emptyList()),
                        )
                    }
                    result.success(payload)
                } catch (t: Throwable) {
                    result.success(emptyMap<String, Any?>())
                }
            }

            "askAgent" -> scope.launch {
                try {
                    val prompt = call.argument<String>("prompt") ?: ""
                    val sourceCurrency = call.argument<String>("sourceCurrency") ?: "USD"
                    val selectedCurrencies = call.argument<List<String>>("selectedCurrencies")
                        ?: listOf("USD")
                    val rawRates = call.argument<Map<String, Number>>("ratesBySymbol")
                        ?: emptyMap()
                    val rates = rawRates.mapValues { it.value.toDouble() }
                    val itemsList = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()

                    val summary = itemsList.joinToString("\n") { item ->
                        "- ${item["amount"]} $sourceCurrency"
                    }

                    val reply = withContext(Dispatchers.Default) {
                        geminiNanoAgent.askAgent(
                            userPrompt = prompt,
                            sourceCurrency = sourceCurrency,
                            selectedCurrencies = selectedCurrencies,
                            ratesBySymbol = rates,
                            scannedItemsSummary = summary,
                        )
                    }

                    result.success(
                        mapOf(
                            "handledByNativeAgent" to reply.handled,
                            "responseText" to reply.responseText,
                            "invokedTools" to reply.invokedTools,
                        ),
                    )
                } catch (t: Throwable) {
                    result.success(mapOf("handledByNativeAgent" to false))
                }
            }

            "disposeSession" -> {
                geminiNanoAgent.closeSession()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun hasLocationPermission(): Boolean {
        val coarse = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val fine = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        return coarse || fine
    }

    private suspend fun requestCoarseLocationPermission(): Boolean {
        val activity = activityRef.get() ?: return false
        if (hasLocationPermission()) return true

        val existing = pendingLocationPermission
        if (existing != null) {
            return withTimeoutOrNull(15_000L) { existing.await() } ?: false
        }

        val deferred = CompletableDeferred<Boolean>()
        pendingLocationPermission = deferred
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION),
            PriceScannerPluginFactory.LOCATION_PERMISSION_REQUEST_CODE,
        )
        return withTimeoutOrNull(30_000L) { deferred.await() } ?: false
    }

    private suspend fun resolveLocationCurrency(): Map<String, Any?> {
        // Tier 1: Coarse/Fine device location -> Geocoder country code
        if (hasLocationPermission()) {
            val location = getBestLocation()
            if (location != null) {
                val geoCountry = reverseGeocodeCountryCode(location.latitude, location.longitude)
                val geoCurrency = countryCodeToCurrency(geoCountry)
                if (geoCountry != null && geoCurrency != null) {
                    return mapOf(
                        "currencyCode" to geoCurrency,
                        "countryCode" to geoCountry,
                        "source" to "gps",
                    )
                }
            }
        }

        // Tier 2: Current cellular network ISO country code (works without permission while roaming/traveling)
        val networkCountry = getCellularNetworkCountryCode()
        val networkCurrency = countryCodeToCurrency(networkCountry)
        if (networkCountry != null && networkCurrency != null) {
            return mapOf(
                "currencyCode" to networkCurrency,
                "countryCode" to networkCountry,
                "source" to "network",
            )
        }

        // Tier 3: Device IANA timezone region (e.g. America/Santo_Domingo -> DO -> DOP, works offline on Wi-Fi)
        val tzCountry = getTimeZoneCountryCode()
        val tzCurrency = countryCodeToCurrency(tzCountry)
        if (tzCountry != null && tzCurrency != null) {
            return mapOf(
                "currencyCode" to tzCurrency,
                "countryCode" to tzCountry,
                "source" to "timezone",
            )
        }

        return emptyMap()
    }

    @SuppressLint("MissingPermission")
    private suspend fun getBestLocation(): Location? {
        val locationManager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null

        val candidateProviders = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(LocationManager.FUSED_PROVIDER)
            }
            add(LocationManager.NETWORK_PROVIDER)
            add(LocationManager.GPS_PROVIDER)
            add(LocationManager.PASSIVE_PROVIDER)
        }

        var bestLast: Location? = null
        val twoHoursMs = 2L * 60L * 60L * 1000L
        val now = System.currentTimeMillis()

        for (provider in candidateProviders) {
            try {
                if (!locationManager.isProviderEnabled(provider)) continue
                val loc = locationManager.getLastKnownLocation(provider) ?: continue
                if (bestLast == null || loc.time > bestLast.time) {
                    bestLast = loc
                }
            } catch (_: Throwable) {
            }
        }

        if (bestLast != null && (now - bestLast.time) <= twoHoursMs) {
            return bestLast
        }

        // Request a single quick coarse fix on API 30+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val freshProvider = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    locationManager.isProviderEnabled(LocationManager.FUSED_PROVIDER) ->
                    LocationManager.FUSED_PROVIDER
                locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ->
                    LocationManager.NETWORK_PROVIDER
                locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ->
                    LocationManager.GPS_PROVIDER
                else -> null
            }
            if (freshProvider != null) {
                val fresh = withTimeoutOrNull(3_500L) {
                    suspendCancellableCoroutine<Location?> { cont ->
                        val signal = CancellationSignal()
                        cont.invokeOnCancellation { signal.cancel() }
                        try {
                            locationManager.getCurrentLocation(
                                freshProvider,
                                signal,
                                context.mainExecutor,
                            ) { loc ->
                                if (cont.isActive) cont.resume(loc)
                            }
                        } catch (_: Throwable) {
                            if (cont.isActive) cont.resume(null)
                        }
                    }
                }
                if (fresh != null) return fresh
            }
        }

        return bestLast
    }

    private suspend fun reverseGeocodeCountryCode(latitude: Double, longitude: Double): String? {
        if (!Geocoder.isPresent()) return null
        val geocoder = Geocoder(context, Locale.US)

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            withTimeoutOrNull(3_500L) {
                suspendCancellableCoroutine<String?> { cont ->
                    try {
                        geocoder.getFromLocation(latitude, longitude, 1) { addresses ->
                            val code = addresses.firstOrNull()?.countryCode?.uppercase(Locale.US)
                            if (cont.isActive) cont.resume(code?.takeIf { it.length == 2 })
                        }
                    } catch (_: Throwable) {
                        if (cont.isActive) cont.resume(null)
                    }
                }
            }
        } else {
            try {
                @Suppress("DEPRECATION")
                val addresses = geocoder.getFromLocation(latitude, longitude, 1)
                addresses?.firstOrNull()?.countryCode?.uppercase(Locale.US)?.takeIf { it.length == 2 }
            } catch (_: Throwable) {
                null
            }
        }
    }

    private fun getCellularNetworkCountryCode(): String? {
        return try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                ?: return null
            if (tm.phoneType == TelephonyManager.PHONE_TYPE_CDMA) return null
            tm.networkCountryIso
                ?.trim()
                ?.uppercase(Locale.US)
                ?.takeIf { it.length == 2 && it.all { ch -> ch in 'A'..'Z' } }
        } catch (_: Throwable) {
            null
        }
    }

    private fun getTimeZoneCountryCode(): String? {
        return try {
            val tzId = java.util.TimeZone.getDefault().id
            val region = android.icu.util.TimeZone.getRegion(tzId)
                ?.trim()
                ?.uppercase(Locale.US)
            region?.takeIf {
                it.length == 2 && it != "ZZ" && it.all { ch -> ch in 'A'..'Z' }
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun countryCodeToCurrency(countryCode: String?): String? {
        if (countryCode.isNullOrBlank() || countryCode.length != 2) return null
        return try {
            val locale = Locale.Builder().setRegion(countryCode.uppercase(Locale.US)).build()
            Currency.getInstance(locale)?.currencyCode
        } catch (_: Throwable) {
            null
        }
    }

    private fun extractNormalizedLines(
        visionText: Text,
        imageWidth: Int,
        imageHeight: Int,
    ): List<Map<String, Any?>> {
        val safeW = imageWidth.coerceAtLeast(1).toDouble()
        val safeH = imageHeight.coerceAtLeast(1).toDouble()
        val result = mutableListOf<Map<String, Any?>>()

        for (block in visionText.textBlocks) {
            for (line in block.lines) {
                val rect = line.boundingBox
                val normalizedBox = if (rect != null) {
                    mapOf(
                        "left" to (rect.left / safeW).coerceIn(0.0, 1.0),
                        "top" to (rect.top / safeH).coerceIn(0.0, 1.0),
                        "width" to (rect.width() / safeW).coerceIn(0.0, 1.0),
                        "height" to (rect.height() / safeH).coerceIn(0.0, 1.0),
                    )
                } else {
                    null
                }
                result.add(
                    mapOf(
                        "text" to line.text,
                        "boundingBox" to normalizedBox,
                    ),
                )
            }
        }
        return result
    }

    private fun loadScaledOrientedBitmap(path: String, maxDimension: Int): Bitmap? {
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, boundsOpts)
        if (boundsOpts.outWidth <= 0 || boundsOpts.outHeight <= 0) return null

        var sampleSize = 1
        while (max(boundsOpts.outWidth / sampleSize, boundsOpts.outHeight / sampleSize) > maxDimension) {
            sampleSize *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val decoded = BitmapFactory.decodeFile(path, decodeOpts) ?: return null

        val rotationDegrees = try {
            val exif = ExifInterface(path)
            when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Throwable) {
            0f
        }

        if (rotationDegrees == 0f) return decoded
        val matrix = Matrix().apply { postRotate(rotationDegrees) }
        val rotated = Bitmap.createBitmap(
            decoded,
            0,
            0,
            decoded.width,
            decoded.height,
            matrix,
            true,
        )
        if (rotated != decoded) decoded.recycle()
        return rotated
    }

    private fun scaleBitmapForAi(source: Bitmap, maxDimension: Int): Bitmap {
        val largest = max(source.width, source.height)
        if (largest <= maxDimension) return source
        val scale = maxDimension.toFloat() / largest.toFloat()
        val targetW = (source.width * scale).toInt().coerceAtLeast(1)
        val targetH = (source.height * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, targetW, targetH, true)
    }
}

private suspend fun <T> Task<T>.awaitTask(): T = suspendCancellableCoroutine { cont ->
    addOnSuccessListener { res ->
        if (cont.isActive) cont.resume(res)
    }
    addOnFailureListener { exc ->
        if (cont.isActive) cont.resumeWithException(exc)
    }
    addOnCanceledListener {
        cont.cancel()
    }
}
