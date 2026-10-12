import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import com.ohos.hapsigntool.HapSignTool;

// 密码通过 stdin 接收，仅在 JVM 内传给签名工具。
public final class OrgTasksHapSigner {
    public static void main(String[] arguments) throws Exception {
        DataInputStream input = new DataInputStream(System.in);
        int length = input.readInt();
        if (length < 1 || length > 65536) throw new IllegalArgumentException("密码长度无效");
        byte[] bytes = new byte[length];
        input.readFully(bytes);
        String password = new String(bytes, StandardCharsets.UTF_8);
        Arrays.fill(bytes, (byte) 0);
        String[] parameters = Arrays.copyOf(arguments, arguments.length + 4);
        parameters[arguments.length] = "-keystorePwd";
        parameters[arguments.length + 1] = password;
        parameters[arguments.length + 2] = "-keyPwd";
        parameters[arguments.length + 3] = password;
        PrintStream output = System.out;
        PrintStream errors = System.err;
        ByteArrayOutputStream messages = new ByteArrayOutputStream();
        PrintStream capture = new PrintStream(messages, true, "UTF-8");
        boolean success = false;
        System.setOut(capture);
        System.setErr(capture);
        try {
            success = HapSignTool.processCmd(parameters);
        } catch (Exception error) {
            capture.println("华为 HAP 签名工具执行失败");
        } finally {
            System.setOut(output);
            System.setErr(errors);
            String text = messages.toString("UTF-8").replace(password, "[密码已隐藏]");
            (success ? output : errors).print(text);
            Arrays.fill(parameters, null);
        }
        if (!success) System.exit(1);
    }
}
