import Darwin
import Foundation

/// libproc 로 같은 사용자의 프로세스를 살펴본다 (별도 권한 불필요).
enum ProcScan {
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    /// 실행 파일 이름이 정확히 `name` 인 프로세스들.
    static func pids(executableNamed name: String) -> [pid_t] {
        allPids().filter { self.name(of: $0) == name }
    }

    /// 프로세스 이름. 실행 파일이 업데이트로 지워진 뒤에도 얻을 수 있다 (proc_pidpath 는 그 경우 실패).
    static func name(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// 프로세스의 명령줄 인자 (argv[0] 포함).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }        // 실행 파일 경로
        while i < size, buf[i] == 0 { i += 1 }        // 패딩
        var args: [String] = []
        while args.count < Int(argc), i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// 프로세스의 현재 작업 폴더.
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r > 0 else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// 터미널에 붙어서 실행 중인 프로세스인지.
    static func hasTTY(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return r > 0 && info.e_tdev != 0 && info.e_tdev != UInt32.max
    }

    /// 프로세스가 열어 둔 파일 경로들.
    static func openFiles(of pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / stride) where Int32(fd.proc_fdtype) == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                   Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard r > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }
}
