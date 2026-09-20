"""
Referenzmodell zu PodcastAICore/SafeHTTP.swift (load/save).

Vorher las die Feed-Seite mit `session.data(for:)` und die Medienseite
pruefte die Groesse erst an der *fertigen* Datei. Beides heisst: ein Server,
der einfach weitersendet, bestimmt, wie viel Speicher oder Platte die App
belegt, bevor irgendjemand nachsieht.

Die Fassung in SafeHTTP prueft an zwei Stellen: an der angekuendigten Laenge,
bevor ein Byte gelesen wird, und am tatsaechlich Gelesenen waehrend des
Lesens. Hier wird gegen ein Servermodell geprueft, das luegen darf.
"""
import sys

LIMIT = 32 * 1024 * 1024


class Rejected(Exception):
    pass


def transfer(announced, actually_sent, limit=LIMIT):
    """Portierung der Grenzpruefung aus SafeHTTP.load/save.

    `announced` ist `expectedContentLength` (-1 heisst "unbekannt"),
    `actually_sent` ist, was der Server wirklich schickt.
    Rueckgabe: die Zahl gelesener Bytes. Wirft, sobald die Grenze faellt.
    """
    if announced > limit:
        raise Rejected("angekuendigt zu gross")

    read = 0
    for _ in range(actually_sent):
        read += 1
        if read > limit:
            raise Rejected("waehrend des Lesens zu gross")
    if read == 0:
        raise Rejected("leer")
    return read


def main():
    checks = 0
    failures = []

    def expect_ok(announced, sent, note):
        nonlocal checks
        checks += 1
        try:
            read = transfer(announced, sent)
        except Rejected as error:
            failures.append(f"{note}: abgelehnt ({error})")
            return
        if read != sent:
            failures.append(f"{note}: {read} gelesen statt {sent}")

    def expect_rejected(announced, sent, note):
        nonlocal checks
        checks += 1
        try:
            transfer(announced, sent)
        except Rejected:
            return
        failures.append(f"{note}: durchgelassen")

    # Kleiner Grenzwert, damit die erschoepfende Pruefung unten bezahlbar ist.
    small = 8

    # 1. Ehrlicher Server, alles innerhalb der Grenze.
    for sent in range(1, small + 1):
        checks += 1
        try:
            read = transfer(sent, sent, limit=small)
            if read != sent:
                failures.append(f"ehrlich, {sent} Bytes: {read} gelesen")
        except Rejected as error:
            failures.append(f"ehrlich, {sent} Bytes: abgelehnt ({error})")

    # 2. Genau an der Grenze: muss durchkommen. Ein Byte darueber: nicht.
    expect_ok(LIMIT, LIMIT, "genau an der Grenze, ehrlich angekuendigt")
    expect_rejected(LIMIT + 1, LIMIT + 1, "ein Byte ueber der Grenze")

    # 3. Der Server luegt nach unten: er kuendigt wenig an und sendet viel.
    #    Genau der Fall, gegen den eine Pruefung *vor* dem Lesen allein nicht
    #    hilft.
    expect_rejected(1, LIMIT + 1, "luegt: kuendigt 1 an, sendet Grenze+1")
    expect_rejected(-1, LIMIT + 1, "kuendigt nichts an, sendet Grenze+1")
    expect_rejected(0, LIMIT + 5, "kuendigt 0 an, sendet Grenze+5")

    # 4. Der Server kuendigt zu viel an und sendet wenig: die Anfrage faellt
    #    trotzdem sofort, ohne ein Byte zu lesen. Das ist gewollt -- die
    #    Ankuendigung ist das Versprechen, an dem man ihn misst.
    expect_rejected(LIMIT + 1, 10, "kuendigt zu viel an, sendet wenig")

    # 5. Leere Antwort ist ein Fehler, kein leerer Feed.
    expect_rejected(0, 0, "leer")
    expect_rejected(-1, 0, "leer, ohne Ankuendigung")

    # 6. Erschoepfend im kleinen Bereich: jede Kombination aus Ankuendigung
    #    und tatsaechlicher Menge. Die Invariante lautet: es werden nie mehr
    #    als `limit` Bytes gelesen, was der Server auch behauptet.
    for announced in range(-1, small + 3):
        for sent in range(0, small + 3):
            checks += 1
            try:
                read = transfer(announced, sent, limit=small)
            except Rejected:
                continue
            if read > small:
                failures.append(
                    f"Invariante verletzt: {read} > {small} "
                    f"(angekuendigt {announced}, gesendet {sent})")
            if read != sent:
                failures.append(
                    f"falsche Menge: {read} statt {sent} "
                    f"(angekuendigt {announced})")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"Transfergrenzen-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"Transfergrenzen-Referenz: {checks} Pruefungen bestanden "
          f"(ehrliche und luegende Ankuendigung, Grenze exakt, "
          f"Kombinationen erschoepfend bis {small}).")
    return 0



if __name__ == "__main__":
    sys.exit(main())
