package com.codex.note8remote;
import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import java.lang.reflect.Field;
/** Supply the package identity required by Samsung's media services. */
final class RootRuntime {
    private static boolean ready;
    static synchronized void ensureContext() throws Exception {
        if(ready)return;
        Class<?> type=Class.forName("android.app.ActivityThread");
        Object thread=type.getMethod("systemMain").invoke(null);
        Context system=(Context)type.getMethod("getSystemContext").invoke(thread);
        Context context=system.createPackageContext("com.codex.note8remote",0);
        Application app=Instrumentation.newApplication(Application.class,context);
        Field initial=type.getDeclaredField("mInitialApplication");initial.setAccessible(true);initial.set(thread,app);
        ready=true;
    }
}
