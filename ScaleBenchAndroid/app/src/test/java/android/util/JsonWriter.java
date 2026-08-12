package android.util;

import java.io.Closeable;
import java.io.Flushable;
import java.io.IOException;
import java.io.Writer;
import java.util.ArrayList;
import java.util.List;

/** JVM-test implementation of the Android streaming JSON writer. */
public final class JsonWriter implements Closeable, Flushable {
    private enum Scope {
        EMPTY_DOCUMENT,
        NONEMPTY_DOCUMENT,
        EMPTY_ARRAY,
        NONEMPTY_ARRAY,
        EMPTY_OBJECT,
        DANGLING_NAME,
        NONEMPTY_OBJECT
    }

    private final Writer output;
    private final List<Scope> stack = new ArrayList<>();
    private String indent = "";

    public JsonWriter(Writer output) {
        if (output == null) throw new NullPointerException("output == null");
        this.output = output;
        stack.add(Scope.EMPTY_DOCUMENT);
    }

    public void setIndent(String indent) {
        this.indent = indent == null ? "" : indent;
    }

    public JsonWriter beginArray() throws IOException {
        beforeValue();
        stack.add(Scope.EMPTY_ARRAY);
        output.write('[');
        return this;
    }

    public JsonWriter endArray() throws IOException {
        return closeScope(Scope.EMPTY_ARRAY, Scope.NONEMPTY_ARRAY, ']');
    }

    public JsonWriter beginObject() throws IOException {
        beforeValue();
        stack.add(Scope.EMPTY_OBJECT);
        output.write('{');
        return this;
    }

    public JsonWriter endObject() throws IOException {
        return closeScope(Scope.EMPTY_OBJECT, Scope.NONEMPTY_OBJECT, '}');
    }

    public JsonWriter name(String name) throws IOException {
        if (name == null) throw new NullPointerException("name == null");
        Scope scope = peek();
        if (scope == Scope.NONEMPTY_OBJECT) {
            output.write(',');
        } else if (scope != Scope.EMPTY_OBJECT) {
            throw new IllegalStateException("Name is not inside an object");
        }
        newline();
        writeString(name);
        output.write(indent.isEmpty() ? ":" : ": ");
        replaceTop(Scope.DANGLING_NAME);
        return this;
    }

    public JsonWriter value(String value) throws IOException {
        if (value == null) return nullValue();
        beforeValue();
        writeString(value);
        return this;
    }

    public JsonWriter value(boolean value) throws IOException {
        beforeValue();
        output.write(value ? "true" : "false");
        return this;
    }

    public JsonWriter value(double value) throws IOException {
        if (Double.isNaN(value) || Double.isInfinite(value)) {
            throw new IllegalArgumentException("Numeric values must be finite");
        }
        beforeValue();
        output.write(Double.toString(value));
        return this;
    }

    public JsonWriter value(long value) throws IOException {
        beforeValue();
        output.write(Long.toString(value));
        return this;
    }

    public JsonWriter value(Number value) throws IOException {
        if (value == null) return nullValue();
        String encoded = value.toString();
        if (encoded.equals("NaN") || encoded.equals("Infinity") || encoded.equals("-Infinity")) {
            throw new IllegalArgumentException("Numeric values must be finite");
        }
        beforeValue();
        output.write(encoded);
        return this;
    }

    public JsonWriter nullValue() throws IOException {
        beforeValue();
        output.write("null");
        return this;
    }

    @Override
    public void flush() throws IOException {
        output.flush();
    }

    @Override
    public void close() throws IOException {
        if (stack.size() != 1 || peek() != Scope.NONEMPTY_DOCUMENT) {
            throw new IOException("Incomplete JSON document");
        }
        stack.clear();
        output.close();
    }

    private JsonWriter closeScope(Scope empty, Scope nonempty, char close) throws IOException {
        Scope scope = peek();
        if (scope != empty && scope != nonempty) {
            throw new IllegalStateException("Nesting problem");
        }
        stack.remove(stack.size() - 1);
        if (scope == nonempty) newline();
        output.write(close);
        return this;
    }

    private void beforeValue() throws IOException {
        Scope scope = peek();
        switch (scope) {
            case EMPTY_DOCUMENT:
                replaceTop(Scope.NONEMPTY_DOCUMENT);
                break;
            case EMPTY_ARRAY:
                replaceTop(Scope.NONEMPTY_ARRAY);
                newline();
                break;
            case NONEMPTY_ARRAY:
                output.write(',');
                newline();
                break;
            case DANGLING_NAME:
                replaceTop(Scope.NONEMPTY_OBJECT);
                break;
            default:
                throw new IllegalStateException("Value is not allowed here");
        }
    }

    private Scope peek() {
        if (stack.isEmpty()) throw new IllegalStateException("JSON writer is closed");
        return stack.get(stack.size() - 1);
    }

    private void replaceTop(Scope scope) {
        stack.set(stack.size() - 1, scope);
    }

    private void newline() throws IOException {
        if (indent.isEmpty()) return;
        output.write('\n');
        for (int index = 1; index < stack.size(); index++) output.write(indent);
    }

    private void writeString(String value) throws IOException {
        output.write('"');
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '"': output.write("\\\""); break;
                case '\\': output.write("\\\\"); break;
                case '\b': output.write("\\b"); break;
                case '\f': output.write("\\f"); break;
                case '\n': output.write("\\n"); break;
                case '\r': output.write("\\r"); break;
                case '\t': output.write("\\t"); break;
                default:
                    if (character <= 0x1f) {
                        output.write(String.format("\\u%04x", (int) character));
                    } else {
                        output.write(character);
                    }
            }
        }
        output.write('"');
    }
}
