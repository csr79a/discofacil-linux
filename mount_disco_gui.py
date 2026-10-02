#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GUI para detectar, montar, desmontar y administrar un disco secundario.

Delega las operaciones privilegiadas a montar_disco.sh y usa sudo mediante
el PTY, igual que en autofirma_gui.py.
"""
from __future__ import annotations

import os
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

from PyQt6.QtCore import QTimer, Qt
from PyQt6.QtGui import QFont
from PyQt6.QtWidgets import (
    QApplication, QHBoxLayout, QHeaderView, QLabel, QLineEdit,
    QMessageBox, QPushButton, QPlainTextEdit, QProgressBar,
    QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget
)

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "montar_disco.sh"

ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
PROMPT_RE = re.compile(r"\[discofacil-sudo\]")

COLUMNS = ["Dispositivo", "Filesystem", "Etiqueta", "UUID", "Tamaño",
           "Montado en", "Inicio automático"]


def run_capture(args):
    return subprocess.run(args, text=True, capture_output=True)


class PtyRunner:
    """Reutiliza el mismo patrón que autofirma_gui.py."""

    def __init__(self, command, on_output, on_done, on_prompt):
        self.command = command
        self.on_output = on_output
        self.on_done = on_done
        self.on_prompt = on_prompt
        self.pid = None
        self.fd = None
        self.prompt_buffer = ""
        self.finished = False
        self._last_cancel = 0.0

    def start(self):
        import pty
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.execvp(self.command[0], self.command)
            except OSError as exc:
                os.write(2, f"ERROR ejecutando {self.command[0]}: {exc}\n".encode())
                os._exit(127)
        os.set_blocking(self.fd, False)

    def _close_fd(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None

    def _reap(self):
        if self.pid is None:
            return False
        try:
            done, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self.pid = None
            return False
        if not done:
            return False
        code = os.waitstatus_to_exitcode(status)
        self.pid = None
        self._finish(code)
        return True

    def _finish(self, code):
        if self.finished:
            return
        self.finished = True
        self._close_fd()
        self.on_done(code)

    def poll(self):
        if self.finished:
            return
        if self.fd is not None:
            try:
                ready, _, _ = select.select([self.fd], [], [], 0)
                if ready:
                    try:
                        data = os.read(self.fd, 8192)
                    except OSError:
                        data = b""
                    if data:
                        text = data.decode("utf-8", "replace")
                        clean = ANSI_RE.sub("", text)
                        self.prompt_buffer = (self.prompt_buffer + clean)[-1000:]
                        last_line = self.prompt_buffer.splitlines()[-1] if self.prompt_buffer.splitlines() else ""
                        if PROMPT_RE.search(last_line.strip()):
                            self.on_prompt(True)
                        self.on_output(text)
                    else:
                        self._close_fd()
            except (OSError, ValueError):
                self._close_fd()
        if not self._reap() and self.fd is None and self.pid is not None:
            return

    def send(self, text):
        if self.fd is not None and not self.finished:
            try:
                os.write(self.fd, text.encode())
                self.on_prompt(False)
            except OSError:
                pass

    def cancel(self):
        if self.finished:
            return
        now = time.monotonic()
        if now - self._last_cancel < 0.8:
            if self.pid is not None:
                try:
                    os.killpg(self.pid, signal.SIGKILL)
                except OSError:
                    try:
                        os.kill(self.pid, signal.SIGKILL)
                    except OSError:
                        pass
        else:
            if self.fd is not None:
                try:
                    os.write(self.fd, b"\x03")
                except OSError:
                    pass
            self.on_prompt(False)
        self._last_cancel = now


class App(QWidget):
    def __init__(self):
        super().__init__()
        self.runner = None
        self.timer = QTimer(self)
        self.timer.timeout.connect(self._poll_runner)
        self.setWindowTitle("Montar disco")
        self.resize(900, 650)
        self._build()
        self.refresh_list()

    def _build(self):
        root = QVBoxLayout(self)

        title = QLabel("Montar disco secundario")
        title.setFont(QFont("Sans", 20, QFont.Weight.Bold))
        root.addWidget(title)

        self.table = QTableWidget(0, len(COLUMNS))
        self.table.setHorizontalHeaderLabels(COLUMNS)
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.itemSelectionChanged.connect(self._on_selection)
        root.addWidget(self.table, 1)

        refresh_row = QHBoxLayout()
        refresh = QPushButton("Actualizar lista")
        refresh.clicked.connect(self.refresh_list)
        refresh_row.addWidget(refresh)
        refresh_row.addStretch()
        root.addLayout(refresh_row)

        mp_row = QHBoxLayout()
        mp_row.addWidget(QLabel("Punto de montaje:"))
        self.mountpoint = QLineEdit()
        self.mountpoint.setPlaceholderText("Selecciona un disco de la tabla")
        mp_row.addWidget(self.mountpoint, 1)
        root.addLayout(mp_row)

        self.mount_btn = QPushButton("Montar y dejar permanente")
        self.mount_btn.setEnabled(False)
        self.mount_btn.clicked.connect(self.mount_selected)
        root.addWidget(self.mount_btn)

        disk_actions = QHBoxLayout()
        self.unmount_btn = QPushButton("Desmontar ahora")
        self.unmount_btn.setEnabled(False)
        self.unmount_btn.clicked.connect(self.unmount_selected)
        disk_actions.addWidget(self.unmount_btn)
        self.disable_btn = QPushButton("Desmontar y quitar del inicio")
        self.disable_btn.setEnabled(False)
        self.disable_btn.clicked.connect(self.disable_selected)
        disk_actions.addWidget(self.disable_btn)
        root.addLayout(disk_actions)

        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setFont(QFont("Monospace", 10))
        root.addWidget(self.log, 1)

        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.hide()
        root.addWidget(self.progress)

        row = QHBoxLayout()
        self.input = QLineEdit()
        self.input.setPlaceholderText("Entrada para el proceso (sudo)")
        self.input.returnPressed.connect(self.send_input)
        row.addWidget(self.input, 1)
        send = QPushButton("Enviar")
        send.clicked.connect(self.send_input)
        row.addWidget(send)
        self.cancel_btn = QPushButton("Cancelar")
        self.cancel_btn.clicked.connect(self.cancel_runner)
        self.cancel_btn.setEnabled(False)
        row.addWidget(self.cancel_btn)
        root.addLayout(row)

    def set_password_mode(self, enabled):
        self.input.setEchoMode(
            QLineEdit.EchoMode.Password if enabled else QLineEdit.EchoMode.Normal
        )
        self.input.setPlaceholderText(
            "Contraseña (oculta)" if enabled else "Entrada para el proceso (sudo)"
        )

    def write(self, text):
        clean = ANSI_RE.sub("", text).replace("\r", "\n")
        if clean:
            self.log.appendPlainText(clean.rstrip("\n"))
            self.log.ensureCursorVisible()

    def refresh_list(self):
        if not SCRIPT.is_file():
            QMessageBox.critical(self, "Error", f"No se encuentra {SCRIPT}")
            return
        p = run_capture(["bash", str(SCRIPT), "--list"])
        if p.returncode != 0:
            self.write("ERROR al listar discos: " + p.stderr.strip())
            return
        self.table.setRowCount(0)
        for line in p.stdout.splitlines():
            parts = line.split("\t", 7)
            if len(parts) != 8:
                continue
            name, fstype, label, uuid, size, mountpoint, fstab_target, fstab_count = parts
            try:
                fstab_count = int(fstab_count)
            except ValueError:
                continue
            row = self.table.rowCount()
            self.table.insertRow(row)
            self.table.setItem(row, 0, QTableWidgetItem(f"/dev/{name}"))
            self.table.setItem(row, 1, QTableWidgetItem(fstype))
            self.table.setItem(row, 2, QTableWidgetItem(label or "(sin etiqueta)"))
            uuid_item = QTableWidgetItem(uuid)
            uuid_item.setData(Qt.ItemDataRole.UserRole, {
                "mountpoint": mountpoint,
                "fstab_target": fstab_target,
                "fstab_count": fstab_count,
            })
            self.table.setItem(row, 3, uuid_item)
            self.table.setItem(row, 4, QTableWidgetItem(size))
            self.table.setItem(row, 5, QTableWidgetItem(mountpoint or "(no montado)"))
            if fstab_count == 1:
                fstab_status = fstab_target or "Entrada inválida"
            elif fstab_count > 1:
                fstab_status = f"Ambiguo ({fstab_count} entradas)"
            else:
                fstab_status = "(no configurado)"
            self.table.setItem(row, 6, QTableWidgetItem(fstab_status))
        if self.table.rowCount() == 0:
            self.write("No se encontraron discos candidatos (sin contar raíz, /boot, swap...).")

    def _on_selection(self):
        rows = self.table.selectionModel().selectedRows()
        if not rows:
            self._update_action_buttons(None)
            return
        row = rows[0].row()
        item = self.table.item(row, 3)
        info = item.data(Qt.ItemDataRole.UserRole) or {}
        label = self.table.item(row, 2).text()
        uuid = item.text()
        suggestion = label if label != "(sin etiqueta)" else uuid[:8]
        suggestion = re.sub(r"[^A-Za-z0-9_.-]", "_", suggestion)
        self.mountpoint.setText(f"/mnt/{suggestion}")
        self._update_action_buttons(info)

    def _update_action_buttons(self, info):
        available = info is not None and self.runner is None
        self.mount_btn.setEnabled(available)
        self.unmount_btn.setEnabled(available and bool(info.get("mountpoint")))
        target = info.get("fstab_target", "") if info else ""
        safe_target = bool(re.fullmatch(r"/mnt/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", target))
        safe_target = safe_target and not any(part in (".", "..") for part in target.split("/"))
        self.disable_btn.setEnabled(
            available and info.get("fstab_count") == 1 and safe_target
        )

    def _selected_disk(self):
        rows = self.table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.table.item(rows[0].row(), 3)
        info = item.data(Qt.ItemDataRole.UserRole) or {}
        return {"uuid": item.text(), **info}

    def mount_selected(self):
        disk = self._selected_disk()
        if not disk:
            return
        uuid = disk["uuid"]
        mountpoint = self.mountpoint.text().strip()
        safe_path = bool(re.fullmatch(r"/mnt/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", mountpoint))
        safe_path = safe_path and not any(part in (".", "..") for part in mountpoint.split("/"))
        if not safe_path:
            QMessageBox.warning(self, "Punto de montaje inválido",
                                 "Usa una ruta sencilla bajo /mnt/, sin espacios ni componentes . o ..")
            return
        self._start_operation(
            f"Montando UUID={uuid} en {mountpoint}",
            ["--mount", uuid, mountpoint],
        )

    def unmount_selected(self):
        disk = self._selected_disk()
        if not disk or not disk.get("mountpoint"):
            return
        uuid = disk["uuid"]
        mountpoint = disk["mountpoint"]
        answer = QMessageBox.question(
            self,
            "Desmontar ahora",
            f"¿Desmontar UUID={uuid} de {mountpoint}?\n\n"
            "Esto no cambia /etc/fstab. Si el disco está configurado para iniciar automáticamente, "
            "volverá a montarse al reiniciar.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self._start_operation(
            f"Desmontando ahora UUID={uuid} de {mountpoint}",
            ["--unmount", uuid, mountpoint],
        )

    def disable_selected(self):
        disk = self._selected_disk()
        if not disk or disk.get("fstab_count") != 1 or not disk.get("fstab_target"):
            return
        uuid = disk["uuid"]
        mountpoint = disk["fstab_target"]
        answer = QMessageBox.question(
            self,
            "Desmontar y quitar del inicio",
            f"¿Desmontar UUID={uuid} de {mountpoint} y quitar su entrada de /etc/fstab?\n\n"
            "Se guardará una copia de fstab. No se borrarán archivos ni se formateará el disco. "
            "Si está ocupado o el montaje no coincide, la operación se abortará.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self._start_operation(
            f"Desmontando y quitando del inicio UUID={uuid} ({mountpoint})",
            ["--disable", uuid, mountpoint],
        )

    def _start_operation(self, description, script_args):
        if self.runner:
            QMessageBox.warning(self, "Proceso activo", "Espera a que termine el proceso actual.")
            return
        self.set_password_mode(False)
        self.write(f"\n=== {description} ===")
        command = ["sudo", "-k", "-p", "[discofacil-sudo] ", "bash", str(SCRIPT), *script_args]
        self.write("$ " + " ".join(command))
        self.runner = PtyRunner(command, self.write, self.finished, self.set_password_mode)
        try:
            self.runner.start()
        except Exception as exc:
            self.runner = None
            self.write(f"ERROR iniciando proceso: {exc}")
            return
        self.progress.show()
        self.cancel_btn.setEnabled(True)
        self._update_action_buttons(self._selected_disk())
        self.timer.start(40)

    def _poll_runner(self):
        if self.runner:
            self.runner.poll()

    def finished(self, code):
        self.timer.stop()
        self.progress.hide()
        self.cancel_btn.setEnabled(False)
        self.set_password_mode(False)
        self.write(f"=== Proceso terminado: código {code} ===")
        self.runner = None
        if code == 0:
            self.refresh_list()
        self._update_action_buttons(self._selected_disk())

    def send_input(self):
        if self.runner:
            self.runner.send(self.input.text() + "\n")
            self.input.clear()

    def cancel_runner(self):
        if self.runner:
            self.runner.cancel()
            self.write("Cancelación solicitada. Una segunda pulsación fuerza la finalización.")


def main():
    if sys.version_info < (3, 10):
        print("Se requiere Python 3.10 o superior.", file=sys.stderr)
        raise SystemExit(1)
    app = QApplication(sys.argv)
    w = App()
    w.show()
    raise SystemExit(app.exec())


if __name__ == "__main__":
    main()
