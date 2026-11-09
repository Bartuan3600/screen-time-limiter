package de.bartuan.eltern

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/** Rein lokale Benachrichtigung, nur solange die App offen ist (kein Hintergrunddienst, kein Push-Dienst). */
object Notifier {
    private const val CHANNEL = "limit"

    fun canNotify(c: Context): Boolean =
        Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(c, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun limitReached(c: Context, name: String) {
        if (!canNotify(c)) return
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Limit erreicht", NotificationManager.IMPORTANCE_DEFAULT))
        val n = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentTitle("Zeit ist um")
            .setContentText("$name hat das Tageslimit erreicht – der PC meldet ab.")
            .setAutoCancel(true)
            .build()
        nm.notify(("limit-$name").hashCode(), n)
    }
}
