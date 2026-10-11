//! The NixOS backend: the service is declared in configuration.nix, so the
//! lifecycle is foreign (up/down/update are no-ops that point at
//! `nixos-rebuild`), while one-offs, logs, health and data discovery reuse
//! the systemd machinery with the release at ${PESQUE_RELEASE}.
const std = @import("std");
const proc = @import("../proc.zig");
const driver = @import("../driver.zig");
const systemd = @import("systemd.zig");

const Error = proc.Error;

pub fn runOnce(self: driver.Nixos, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    return systemd.runOnce(.{ .unit = self.unit, .release = self.release }, host, ro);
}

pub fn noopLifecycle(self: driver.Nixos, host: *proc.Host, action: []const u8) Error!u8 {
    _ = self;
    host.note("nothing to do for '{s}': the NixOS module owns the service. Run 'nixos-rebuild switch' to apply changes.", .{action});
    return 0;
}

pub fn noopUpdate(self: driver.Nixos, host: *proc.Host) Error!u8 {
    _ = self;
    host.note("nothing to update: the release comes from your NixOS configuration. Set services.pesque.package and run 'nixos-rebuild switch'.", .{});
    return 0;
}

pub fn restart(self: driver.Nixos, host: *proc.Host) Error!u8 {
    return systemd.restart(.{ .unit = self.unit, .release = self.release }, host);
}

pub fn logs(self: driver.Nixos, host: *proc.Host, opts: driver.LogOpts) Error!u8 {
    return systemd.logs(.{ .unit = self.unit, .release = self.release }, host, opts);
}

pub fn health(self: driver.Nixos, host: *proc.Host) Error!driver.Health {
    return systemd.health(.{ .unit = self.unit, .release = self.release }, host);
}

pub fn dataDir(self: driver.Nixos, host: *proc.Host) Error!driver.DataDir {
    return systemd.dataDir(.{ .unit = self.unit, .release = self.release }, host);
}
