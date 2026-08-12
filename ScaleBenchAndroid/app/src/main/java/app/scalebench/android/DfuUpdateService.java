package app.scalebench.android;

import android.app.Activity;

import no.nordicsemi.android.dfu.DfuBaseService;

public class DfuUpdateService extends DfuBaseService {
    @Override
    protected Class<? extends Activity> getNotificationTarget() {
        return MainActivity.class;
    }

    @Override
    protected boolean isDebug() {
        return BuildConfig.DEBUG;
    }
}
