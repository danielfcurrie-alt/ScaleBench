package app.scalebench.android;

final class CoreSmokeTest {
    public static void main(String[] args) {
        testWmbPlusCapabilitiesParse();
        testWmbPlusExtendedPacketParse();
        testBookooPacketParse();
        testAdditionalParsers();
        testAnalyzerScoresRecording();
        System.out.println("Core smoke tests passed");
    }

    private static void testWmbPlusCapabilitiesParse() {
        byte[] data = bytes(0x03, 0x0C, 0x01, 0x10, 0x01, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x07, 0x00, 0x01, 0x14, 0x00, 0x8D);
        WmbPlusCapabilities capabilities = ScaleParsers.parseCapabilities(data);
        check(capabilities != null, "capabilities parsed");
        check(capabilities.featureMask == 0x0000_7FFFL, "feature mask");
        check(capabilities.preferredAtomicCommand == 0x07, "preferred command");
        check(capabilities.supportsExtendedPacket(), "extended packet");
    }

    private static void testWmbPlusExtendedPacketParse() {
        WmbPlusCapabilities capabilities = ScaleParsers.parseCapabilities(
                bytes(0x03, 0x0C, 0x01, 0x10, 0x01, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x07, 0x00, 0x01, 0x14, 0x00, 0x8D)
        );
        byte[] packet = bytes(
                0x03, 0x0B,
                0x00, 0x12, 0x34,
                0x01,
                0x2B, 0x00, 0x09, 0xC4,
                0x2B, 0x00, 0xFA,
                0x55,
                0xFE,
                0x43,
                0x61,
                0x0C,
                0xEC,
                0x00
        );
        packet[19] = (byte) xor(packet, 19);
        ParserResult result = ScaleParsers.parseWmb20(packet, capabilities, 0, 10);
        check(result.isSample(), "wmb sample");
        ScaleSample sample = result.sample;
        check(sample.scaleKind == ScaleKind.WEIGH_MY_BRU_PLUS, "wmb kind");
        close(sample.weightGrams, 25.0, "wmb weight");
        close(sample.flowGramsPerSecond, 2.5, "wmb flow");
        check(sample.batteryPercent == 85, "wmb battery");
        check(sample.sequence == 254, "wmb sequence");
        check(sample.statusFlags.timerRunning, "timer flag");
        check(sample.statusFlags.batteryPresent, "battery present");
        check(sample.firmwareQualityScore == 97, "quality");
        check(sample.detectedSampleRateHz == 12, "sample rate");
        check(sample.diagnosticFlags.extensionPresent, "extension flag");
        check(sample.diagnosticFlags.detected80Sps, "80 SPS flag");
    }

    private static void testBookooPacketParse() {
        byte[] packet = bytes(
                0x03, 0x0B,
                0x00, 0x10, 0x00,
                0x02,
                0x2D, 0x00, 0x00, 0x64,
                0x2B, 0x00, 0xC8,
                0x63,
                0, 30, 2, 0, 1, 0
        );
        packet[19] = (byte) xor(packet, 19);
        ParserResult result = ScaleParsers.parseBookoo(packet, ScaleKind.BOOKOO_ULTRA, 0, 1);
        check(result.isSample(), "bookoo sample");
        ScaleSample sample = result.sample;
        check(sample.scaleKind == ScaleKind.BOOKOO_ULTRA, "bookoo kind");
        close(sample.weightGrams, -1.0, "bookoo weight");
        close(sample.flowGramsPerSecond, 2.0, "bookoo flow");
        check(sample.batteryPercent == 99, "bookoo battery");
    }

    private static void testAdditionalParsers() {
        byte[] acaiaFrame = bytes(0xEF, 0xDD, 0x0C, 0x04, 0x7B, 0x00, 0x01, 0x00, 0x7C, 0x00);
        ParserResult acaia = new AcaiaCodec().receive(acaiaFrame, 0, 1).get(0);
        check(acaia.isSample(), "acaia sample");
        close(acaia.sample.weightGrams, 12.3, "acaia weight");

        ParserResult decent = ScaleParsers.parseDecentEspressi(bytes(0x03, 0xCE, 0x00, 0x7B, 0x00, 0x01, 0x02, 0x03, 0x00, 0x00), ScaleKind.DECENT, 0, 1);
        check(decent.isSample(), "decent sample");
        close(decent.sample.weightGrams, 12.3, "decent weight");
        check(decent.sample.deviceTimestampMilliseconds == 62_300L, "decent timestamp");

        ParserResult difluidSensor = ScaleParsers.parseDiFluid(bytes(0xDF, 0xDF, 0x03, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x7B, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, 0x00, 0x00), ScaleKind.DIFLUID_TI, 0, 1);
        byte[] difluidBytes = bytes(0xDF, 0xDF, 0x03, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x7B, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, 0x00, 0x00);
        difluidBytes[difluidBytes.length - 1] = (byte) additive(difluidBytes, difluidBytes.length - 1);
        difluidSensor = ScaleParsers.parseDiFluid(difluidBytes, ScaleKind.DIFLUID_TI, 0, 1);
        check(difluidSensor.isSample(), "difluid sample");
        close(difluidSensor.sample.weightGrams, 12.3, "difluid weight");

        ParserResult eureka = ScaleParsers.parseEureka(bytes(0xAA, 0x09, 0x41, 0x00, 0x1D, 0x00, 0x00, 0x7B, 0x00, 0x00, 0x00), 0, 1);
        check(eureka.isSample(), "eureka sample");
        close(eureka.sample.weightGrams, 12.3, "eureka weight");

        byte[] felicitaBytes = bytes(0, 0, 0x2D, 0x30, 0x30, 0x30, 0x31, 0x32, 0x33, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        ParserResult felicita = ScaleParsers.parseFelicita(felicitaBytes, 0, 1);
        check(felicita.isSample(), "felicita sample");
        close(felicita.sample.weightGrams, -1.23, "felicita weight");

        ParserResult futula = ScaleParsers.parseFutula(bytes(0, 0, 0, 0x7B, 0x00, 0x01, 0, 0, 0), 0, 1);
        check(futula.isSample(), "futula sample");
        close(futula.sample.weightGrams, -12.3, "futula weight");

        ParserResult skale = ScaleParsers.parseSkale2(bytes(0x00, 0x7B, 0x00), 0, 1);
        check(skale.isSample(), "skale sample");
        close(skale.sample.weightGrams, 12.3, "skale weight");

        byte[] timemoreFrame = ScaleParsers.timemoreFrame(0x01, 0x01, new int[] {0x00, 0x00, 0x00, 0x7B, 0, 0, 0, 0});
        ParserResult timemore = new TimemoreDotCodec().receive(timemoreFrame, 0, 1).get(0);
        check(timemore.isSample(), "timemore sample");
        close(timemore.sample.weightGrams, 12.3, "timemore weight");
    }

    private static void testAnalyzerScoresRecording() {
        ScaleRecording recording = ScaleRecording.empty(RecordingMode.IDLE_STABILITY);
        for (int i = 0; i < 10; i++) {
            ScaleSample sample = new ScaleSample();
            sample.arrivalTimeMillis = i * 100L;
            sample.monotonicSeconds = i / 10.0;
            sample.scaleKind = ScaleKind.WEIGH_MY_BRU_PLUS;
            sample.weightGrams = 0.01 * (i % 2);
            sample.deviceTimestampMilliseconds = (long) i * 100;
            recording.samples.add(sample);
        }
        recording.metrics = ScaleQualityAnalyzer.analyze(recording);
        check(recording.metrics.overallScore != null, "overall score");
        check(recording.metrics.effectiveSampleRateHz != null, "sample rate");
        check(recording.metrics.longGapCount == 0, "long gaps");
    }

    private static byte[] bytes(int... values) {
        byte[] bytes = new byte[values.length];
        for (int i = 0; i < values.length; i++) bytes[i] = (byte) values[i];
        return bytes;
    }

    private static int xor(byte[] bytes, int count) {
        int result = 0;
        for (int i = 0; i < count; i++) result ^= bytes[i] & 0xFF;
        return result & 0xFF;
    }

    private static int additive(byte[] bytes, int count) {
        int result = 0;
        for (int i = 0; i < count; i++) result = (result + (bytes[i] & 0xFF)) & 0xFF;
        return result;
    }

    private static void close(Double actual, double expected, String label) {
        check(actual != null && Math.abs(actual - expected) < 0.001, label + " expected " + expected + " got " + actual);
    }

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
    }
}
