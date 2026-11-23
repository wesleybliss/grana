package com.gammagamma.grana.scanner

import androidx.appfunctions.AppFunctionAccessLevel
import androidx.appfunctions.AppFunctionContext
import androidx.appfunctions.AppFunctionDeclaration
import androidx.appfunctions.ExperimentalAppFunctionsApi
import androidx.appfunctions.metadata.AppFunctionMetadata
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.round

/**
 * Thread-safe in-memory store holding Grana's latest offline exchange rates
 * (relative to 1.0 USD) synced from Dart Drift DB for on-device agent tools.
 */
object GranaAgentRateStore {
    private val ratesToUsd = ConcurrentHashMap<String, Double>().apply {
        put("USD", 1.0)
    }

    fun updateRates(rates: Map<String, Double>) {
        ratesToUsd.putAll(rates)
        ratesToUsd["USD"] = 1.0
    }

    fun convert(amount: Double, fromCurrency: String, toCurrency: String): Double {
        val from = fromCurrency.trim().uppercase()
        val to = toCurrency.trim().uppercase()
        if (from == to) return roundTwoDecimals(amount)

        val fromRate = ratesToUsd[from] ?: 1.0
        val toRate = ratesToUsd[to] ?: 1.0
        if (fromRate <= 0.0) return roundTwoDecimals(amount)

        val usdValue = if (from == "USD") amount else amount / fromRate
        val converted = if (to == "USD") usdValue else usdValue * toRate
        return roundTwoDecimals(converted)
    }

    private fun roundTwoDecimals(value: Double): Double = round(value * 100.0) / 100.0
}

/**
 * Local Android AppFunctions restricted strictly to this app's internal
 * Gemini Nano 4 AgentRunner (`ACCESS_LEVEL_SELF`).
 */
class GranaAgentTools {
    /**
     * Converts a monetary amount from one 3-letter ISO currency code to another
     * using Grana's cached exchange rates.
     *
     * @param amount Numeric price amount to convert
     * @param fromCurrency Source 3-letter ISO currency code (for example MXN, JPY, EUR)
     * @param toCurrency Target 3-letter ISO currency code (for example USD, EUR, GBP)
     */
    @OptIn(ExperimentalAppFunctionsApi::class)
    @AppFunctionDeclaration(isDescribedByKDoc = true)
    @AppFunctionAccessLevel(
        level = AppFunctionMetadata.ACCESS_LEVEL_SELF,
        isCompatEnforcementEnabled = true,
    )
    fun convert_currency(
        context: AppFunctionContext,
        amount: Double,
        fromCurrency: String,
        toCurrency: String,
    ): Double {
        return GranaAgentRateStore.convert(amount, fromCurrency, toCurrency)
    }

    /**
     * Adds a percentage tip or service charge to a subtotal and splits it evenly
     * across one or more people, returning the per-person amount.
     *
     * @param subtotal Base subtotal before tip
     * @param tipPercent Tip or tax percentage to add (for example 15.0 for 15%)
     * @param splitCount Number of people splitting the bill (1 if not splitting)
     */
    @OptIn(ExperimentalAppFunctionsApi::class)
    @AppFunctionDeclaration(isDescribedByKDoc = true)
    @AppFunctionAccessLevel(
        level = AppFunctionMetadata.ACCESS_LEVEL_SELF,
        isCompatEnforcementEnabled = true,
    )
    fun calculate_tip_and_split(
        context: AppFunctionContext,
        subtotal: Double,
        tipPercent: Double,
        splitCount: Int,
    ): Double {
        val safeSplit = splitCount.coerceAtLeast(1)
        val total = subtotal * (1.0 + tipPercent / 100.0)
        return round((total / safeSplit) * 100.0) / 100.0
    }

    /**
     * Sums a comma-separated list of numeric menu or receipt item prices.
     *
     * @param csvAmounts Comma-separated numeric amounts such as "85.0,120.5,45.0"
     */
    @OptIn(ExperimentalAppFunctionsApi::class)
    @AppFunctionDeclaration(isDescribedByKDoc = true)
    @AppFunctionAccessLevel(
        level = AppFunctionMetadata.ACCESS_LEVEL_SELF,
        isCompatEnforcementEnabled = true,
    )
    fun sum_menu_prices(
        context: AppFunctionContext,
        csvAmounts: String,
    ): Double {
        val sum = csvAmounts
            .split(",")
            .mapNotNull { it.trim().toDoubleOrNull() }
            .sum()
        return round(sum * 100.0) / 100.0
    }
}
