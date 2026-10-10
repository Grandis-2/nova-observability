import com.sun.management.HotSpotDiagnosticMXBean;
import java.lang.management.ManagementFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;

/**
 * 앱이 남기는 로그 한 줄을 흉내 낸다: SLF4J 2 key-value(event_id 등) + MDC(traceId, subject).
 * subject 는 일부러 넣는다 — 에이전트 설정이 MDC 를 traceId 만 받는지 보려고.
 * 에이전트가 붙은 JVM 에서 돌린다. 인자: event_id
 */
public class Probe {
    public static void main(String[] args) throws Exception {
        Logger log = LoggerFactory.getLogger("agent-probe");
        MDC.put("traceId", "req-" + args[0].substring(0, 8));
        MDC.put("subject", "member-42");
        log.atInfo()
                .addKeyValue("event_id", args[0])
                .addKeyValue("aggregate_type", "PROBE")
                .log("outbox published");
        MDC.clear();

        HotSpotDiagnosticMXBean hs = ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);
        System.out.println("probe: java " + Runtime.version()
                + " MaxRAMPercentage=" + hs.getVMOption("MaxRAMPercentage").getValue()
                + " ExitOnOutOfMemoryError=" + hs.getVMOption("ExitOnOutOfMemoryError").getValue()
                + " javaagent=" + ManagementFactory.getRuntimeMXBean().getInputArguments().stream()
                        .anyMatch(a -> a.startsWith("-javaagent:")));
        // 에이전트는 종료 훅에서 남은 로그를 내보낸다. 그 전에 배치 주기(1s)를 한 번 넘긴다.
        Thread.sleep(2000);
    }
}
