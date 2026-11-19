package com.example.employeepos2

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Bundle
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.RecyclerView
import androidx.test.core.app.ApplicationProvider
import com.google.android.material.button.MaterialButton
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/**
 * R1 release hold evidence (scratch only, never committed): build 34 (551c61b, unchanged) given the exact answer the R1
 * backend returns for a checkout with matched and unmatched lines. Prints what the employee is shown and writes PNGs.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-xxhdpi")
class R1PartialCheckoutTest {

    private val app get() = ApplicationProvider.getApplicationContext<Context>()
    private val out = File("build/shots").apply { mkdirs() }

    /** The answer printed by r1hold/mixed_checkout.js from the real R1 router. */
    private val r1Partial = """{"status":"partial","itemsUpdated":2,"lines":[{"jobNumber":"4001","name":"Stop Mold | 7' White","qtyUsed":2,"outcome":"not_stocked","error":"No part with this name on the Inventory sheet, so nothing came off stock."},{"jobNumber":"4001","name":"Keypad | Genie","qtyUsed":1,"outcome":"deducted","remaining":8},{"jobNumber":"4002","name":"Keypad | Genie","qtyUsed":1,"outcome":"deducted","remaining":8}],"message":"1 of 3 lines did not come off stock: Stop Mold | 7' White."}"""

    /** /get_job_materials as R1 serves it for those jobs: Stop Mold has no Sheet row, so inInventory is false. */
    private val list = """[
        {"jobNumber":"4001","customer":"Steven Jones","city":"Springdale","poNumber":"","description":"Weather seal and keypad","notes":"","items":[
            {"name":"Stop Mold | 7' White","qtyNeeded":2,"qtyInStock":0,"description":"","inInventory":false},
            {"name":"Keypad | Genie","qtyNeeded":1,"qtyInStock":10,"description":"","inInventory":true}]},
        {"jobNumber":"4002","customer":"Maria Alvarez","city":"Rogers","poNumber":"","description":"Keypad","notes":"","items":[
            {"name":"Keypad | Genie","qtyNeeded":1,"qtyInStock":10,"description":"","inInventory":true}]}]"""
    /** A third job still to pick, so the "still to pick" message path is shown too. */
    private val thirdJob = """{"jobNumber":"4003","customer":"Lee Park","city":"Bentonville","poNumber":"","description":"Spring","notes":"","items":[
            {"name":"Torsion Spring 207x2x22","qtyNeeded":1,"qtyInStock":14,"description":"","inInventory":true}]}"""

    private inner class Fake(private val lists: List<String>, private val answer: String) : PickListApi.Backend {
        var loads = 0
        val checkouts = CopyOnWriteArrayList<JSONObject>()
        override fun materials(techName: String): String = lists[(loads++).coerceAtMost(lists.size - 1)]
        override fun checkout(payload: JSONObject): String { checkouts += payload; return answer }
    }

    private class Host : AppCompatActivity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            setTheme(R.style.Theme_EmployeePOS2_SiteCheck)
            super.onCreate(savedInstanceState)
            setContentView(FrameLayout(this).apply { id = CONTAINER })
        }
    }

    @Before fun setUp() {
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        val f = SecurePrefs::class.java.getDeclaredField("cached"); f.isAccessible = true
        f.set(null, app.getSharedPreferences("r1_partial_prefs", Context.MODE_PRIVATE).also { it.edit().clear().commit() })
        SecurePrefs.get().edit().putString(Pref.NAME, "Brett Miller").putString(Pref.SAVED_USERNAME, "bmiller")
            .putString(Pref.ROLE, "Technician").putBoolean(Pref.IS_ADMIN, false).commit()
    }

    @After fun tearDown() { PickListApi.backend = PickListApi.Http }

    private fun open(fake: Fake): ActivityController<Host> {
        PickListApi.backend = fake
        val c = Robolectric.buildActivity(Host::class.java).setup()
        c.get().supportFragmentManager.beginTransaction().replace(CONTAINER, InventoryFragmentV2()).commitNow()
        settle(c)
        return c
    }

    private fun settle(c: ActivityController<Host>, until: () -> Boolean = { true }) {
        val end = System.currentTimeMillis() + 4000
        do { repeat(5) { shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(10) } } while (!until() && System.currentTimeMillis() < end)
        shadowOf(Looper.getMainLooper()).idleFor(1, TimeUnit.SECONDS)
        layout(c)
    }

    private fun layout(c: ActivityController<Host>) {
        val root = c.get().findViewById<View>(android.R.id.content)
        val dm = c.get().resources.displayMetrics
        repeat(3) {
            root.measure(View.MeasureSpec.makeMeasureSpec(dm.widthPixels, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(dm.heightPixels, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, dm.widthPixels, dm.heightPixels)
            shadowOf(Looper.getMainLooper()).idle()
        }
    }

    private fun walk(v: View, visit: (View) -> Unit) { visit(v); if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i), visit) }

    private fun rows(c: ActivityController<Host>): List<View> {
        val outRows = mutableListOf<View>()
        layout(c)
        walk(c.get().findViewById<RecyclerView>(R.id.rvInventoryJobs)) { if (it.id == R.id.partRow) outRows += it }
        return outRows
    }

    /** Every visible text on screen, top to bottom, as the person reads it. */
    private fun screenText(c: ActivityController<Host>): List<String> {
        val texts = mutableListOf<String>()
        walk(c.get().window.decorView) { if (it is TextView && it.isShown && it.text.isNotBlank()) texts += it.text.toString() }
        return texts
    }

    private fun shoot(c: ActivityController<Host>, name: String) {
        layout(c)
        val root = c.get().window.decorView
        val bmp = Bitmap.createBitmap(root.width.coerceAtLeast(1), root.height.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp); canvas.drawColor(Color.WHITE); root.draw(canvas)
        FileOutputStream(File(out, "r1_$name.png")).use { bmp.compress(Bitmap.CompressFormat.PNG, 90, it) }
    }

    private fun tickAllAndCheckOut(c: ActivityController<Host>, fake: Fake) {
        for (r in rows(c)) { r.performClick(); shadowOf(Looper.getMainLooper()).idle() }
        println("R1HOLD button before checkout: " + c.get().findViewById<MaterialButton>(R.id.btnCheckout).text)
        c.get().findViewById<MaterialButton>(R.id.btnCheckout).performClick()
        settle(c) { fake.checkouts.isNotEmpty() && fake.loads >= 2 }
        settle(c)
    }

    @Test fun mixedCheckoutListEmptiesAfterwards() {
        val fake = Fake(listOf(list, "[]"), r1Partial)
        val c = open(fake)
        println("R1HOLD [A] before checkout, rows: " + rows(c).map { r -> mutableListOf<String>().also { t -> walk(r) { v -> if (v is TextView && v.isShown && v.text.isNotBlank()) t += v.text.toString() } } })
        shoot(c, "A1_before")
        tickAllAndCheckOut(c, fake)
        println("R1HOLD [A] sent: " + fake.checkouts.firstOrNull()?.getJSONArray("items"))
        println("R1HOLD [A] after checkout, screen: " + screenText(c))
        shoot(c, "A2_after")
    }

    @Test fun mixedCheckoutWithAJobLeft() {
        val withThird = list.trimEnd().removeSuffix("]") + "," + thirdJob + "]"
        val fake = Fake(listOf(withThird, "[$thirdJob]"), r1Partial)
        val c = open(fake)
        for (r in rows(c)) {
            val name = r.findViewById<TextView>(R.id.tvPartName).text.toString()
            if (name.startsWith("Torsion")) continue
            r.performClick(); shadowOf(Looper.getMainLooper()).idle()
        }
        c.get().findViewById<MaterialButton>(R.id.btnCheckout).performClick()
        settle(c) { fake.checkouts.isNotEmpty() && fake.loads >= 2 }
        settle(c)
        println("R1HOLD [B] sent: " + fake.checkouts.firstOrNull()?.getJSONArray("items"))
        println("R1HOLD [B] after checkout, screen: " + screenText(c))
        shoot(c, "B_after")
    }

    private companion object { const val CONTAINER = 0x7f0f1236 }
}
