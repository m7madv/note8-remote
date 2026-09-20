package com.codex.note8remote;
import android.content.*;
public final class BootReceiver extends BroadcastReceiver{
 @Override public void onReceive(Context c,Intent i){if(Intent.ACTION_BOOT_COMPLETED.equals(i.getAction())&&c.getSharedPreferences("remote",0).getBoolean("enabled",false))c.startForegroundService(new Intent(c,RemoteService.class));}
}
