package com.codex.note8remote;

import android.content.ContentResolver;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ImageDecoder;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.system.Os;
import java.io.*;
import java.nio.charset.StandardCharsets;

final class MediaFiles {
    static final String DIR = "/storage/emulated/0/DCIM/Camera1/";
    static File file(String name) { return new File(DIR, name); }
    static boolean imageMode() {
        try (FileInputStream input = new FileInputStream(file("source-mode.txt"))) {
            byte[] buffer = new byte[16];
            int size = input.read(buffer);
            return size > 0 && "image".equals(new String(buffer, 0, size, StandardCharsets.UTF_8).trim());
        } catch (IOException ignored) { return false; }
    }
    static File selected() { return file(imageMode() ? "virtual-image.png" : "virtual.mp4"); }
    static File originalImage() { return file("image-original.bin").isFile() ? file("image-original.bin") : file("virtual-image.png"); }
    static BitmapFactory.Options originalInfo() {
        BitmapFactory.Options info = new BitmapFactory.Options(); info.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(originalImage().getAbsolutePath(), info); return info;
    }
    static String resolutionLabel() {
        if (!imageMode()) return "";
        BitmapFactory.Options info = originalInfo();
        return info.outWidth > 0 ? "دقة الأصل: \u2066" + info.outWidth + " × " + info.outHeight + "\u2069 بكسل" : "";
    }
    static boolean active() { return selected().canRead() && !file("disable.jpg").exists(); }
    static void ensureDirectory() throws IOException {
        File directory = new File(DIR);
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("تعذّر إنشاء مجلد الوسائط. تحقق من إذن التخزين.");
    }
    static void setActive(boolean enabled) throws IOException {
        ensureDirectory();
        if (enabled) {
            if (file("disable.jpg").exists() && !file("disable.jpg").delete()) throw new IOException("تعذّر تفعيل المعاينة.");
        } else if (!file("disable.jpg").exists() && !file("disable.jpg").createNewFile()) {
            throw new IOException("تعذّر إيقاف الاستبدال.");
        }
    }
    private static void replace(File from, File to) throws IOException {
        try { Os.rename(from.getAbsolutePath(), to.getAbsolutePath()); }
        catch (Exception error) { throw new IOException("تعذّر حفظ الملف الجديد.", error); }
    }
    static Bitmap thumbnail() {
        File source = selected();
        if (!source.canRead()) return null;
        if (imageMode()) {
            BitmapFactory.Options options = new BitmapFactory.Options();
            options.inSampleSize = 2;
            return BitmapFactory.decodeFile(source.getAbsolutePath(), options);
        }
        MediaMetadataRetriever reader = new MediaMetadataRetriever();
        try {
            reader.setDataSource(source.getAbsolutePath());
            return reader.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 640, 360);
        } catch (Exception ignored) { return null; }
        finally { try { reader.release(); } catch (Exception ignored) {} }
    }
    static void importMedia(ContentResolver resolver, Uri uri, boolean image) throws IOException {
        ensureDirectory();
        File temporary = File.createTempFile("note8-import-", image ? ".png" : ".mp4", new File(DIR));
        File modeTemp = null;
        File originalTemp = null;
        try {
            if (image) {
                // Preserve the selected file byte for byte. Decode only a separate
                // bounded preview, never use that preview as the saved photograph.
                originalTemp = File.createTempFile("note8-original-", ".bin", new File(DIR));
                try (InputStream input = resolver.openInputStream(uri); FileOutputStream output = new FileOutputStream(originalTemp)) {
                    if (input == null) throw new IOException("تعذّر فتح الصورة.");
                    byte[] buffer = new byte[128 * 1024]; int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                }
                Bitmap bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(originalTemp), (decoder, info, source) -> {
                    int width = info.getSize().getWidth(), height = info.getSize().getHeight();
                    float scale = Math.min(1f, 1920f / Math.max(width, height));
                    decoder.setTargetSize(Math.max(1, Math.round(width * scale)), Math.max(1, Math.round(height * scale)));
                    decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
                });
                try (FileOutputStream output = new FileOutputStream(temporary)) {
                    if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) throw new IOException("تعذّر قراءة الصورة.");
                } finally { bitmap.recycle(); }
            } else {
                try (InputStream input = resolver.openInputStream(uri); FileOutputStream output = new FileOutputStream(temporary)) {
                    if (input == null) throw new IOException("تعذّر فتح الفيديو.");
                    byte[] buffer = new byte[128 * 1024]; int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                }
                MediaMetadataRetriever reader = new MediaMetadataRetriever();
                try {
                    reader.setDataSource(temporary.getAbsolutePath());
                    String width = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH);
                    if (width == null || Integer.parseInt(width) <= 0) throw new IOException("اختر ملف فيديو صالحاً.");
                } catch (RuntimeException error) { throw new IOException("هذا الفيديو غير قابل للقراءة. جرّب فيديو بصيغة MP4.", error); }
                finally { try { reader.release(); } catch (Exception ignored) {} }
            }
            modeTemp = File.createTempFile("note8-mode-", ".txt", new File(DIR));
            try (FileOutputStream output = new FileOutputStream(modeTemp)) {
                output.write((image ? "image" : "video").getBytes(StandardCharsets.UTF_8));
            }
            replace(temporary, file(image ? "virtual-image.png" : "virtual.mp4"));
            if (image) replace(originalTemp, file("image-original.bin"));
            replace(modeTemp, file("source-mode.txt"));
            setActive(true);
        } finally {
            temporary.delete();
            if (modeTemp != null) modeTemp.delete();
            if (originalTemp != null) originalTemp.delete();
        }
    }
}

