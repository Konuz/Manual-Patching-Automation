# Plan: krokowy kreator patchingu Windows Server

## Założenia

Powstanie nowe narzędzie dla VM w vSphere, uruchamiane w 64-bitowym Windows PowerShellu 5.1 na stacji sterującej i gościach. Projekt `F:\Apki\Patching automation` posłuży jako wzorzec; nowa implementacja trafi domyślnie do pustego katalogu `F:\Apki\Patching Automation v2`. Nie będzie używać WinRM ani zmieniać skonfigurowanego na serwerach źródła aktualizacji WUA.

**Cała implementacja będzie po angielsku:** nazwy w kodzie, teksty GUI, komunikaty, logi, raporty i dokumentacja. Plan pozostaje po polsku dla czytelności rozmowy.

## Przebieg w GUI

Jedno okno WinForms pokazuje sześć kroków, tabelę VM i bieżący postęp. Długie operacje nie blokują okna.

1. **Settings:** vCenter, VM wpisane ręcznie lub wczytane z pliku, poświadczenia, katalog wyników, równoległość skanowania i instalacji (domyślnie 3 VM) oraz wielkość paczki restartów (domyślnie 1). Limity skanu 30 min, instalacji 180 min i potwierdzenia restartu 30 min znajdą się w zwijanych ustawieniach zaawansowanych. Odrzucone poświadczenia dają wybór: ponów, pomiń dane konto w tym przebiegu albo zatrzymaj.
   
   Na tym samym pierwszym ekranie będą **dwa niezależne pola**, domyślnie odznaczone: **Ignore vCenter certificate** i **Ignore ESXi certificates for file transfers**. Pierwsze ustawia `InvalidCertificateAction Ignore` tylko w bieżącej sesji PowerCLI; drugie wyłącza weryfikację certyfikatu wyłącznie w połączeniach `curl.exe` do ESXi. Włączenie jednej opcji nie włącza drugiej. GUI objaśnia, że pominięcie weryfikacji nie potwierdza tożsamości serwera. Wybór jest zapisywany w stanie przebiegu i raporcie, aby wznowienie zachowało te same ustawienia. [PowerCLI](https://developer.broadcom.com/powercli/latest/vmware.vimautomation.core/commands/set-powercliconfiguration), [curl](https://curl.se/docs/sslcerts.html).
2. **Scan:** narzędzie wiąże VM z konkretnym vCenter i identyfikatorem obiektu; niejednoznaczna nazwa lub niezgodny FQDN gościa blokuje tę VM. Agent lokalnie odczytuje aktualizacje WUA, zaległy restart i członkostwo w klastrze.
3. **Select updates:** wszystkie aktualizacje oferowane przez WUA są wstępnie zaznaczone. Sterowniki i pakiety opcjonalne są wyraźnie oznaczone; operator może odznaczyć każdą pozycję. Plan pokazuje wybór osobno dla każdej VM i wymaga jawnego zatwierdzenia instalacji. Aktualizacje wymagające akceptacji licencji są wskazane przed zatwierdzeniem. Identyfikatorem wyboru jest `UpdateID + RevisionNumber`. [Tożsamość aktualizacji WUA](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-iupdateidentity).
4. **Install:** agent ponawia wyszukiwanie bezpośrednio przed instalacją i instaluje tylko zatwierdzone rewizje, które nadal są oferowane. Zniknięcie lub zmiana rewizji trafia do raportu; nowa rewizja wymaga wyboru w kolejnej rundzie. Wynik każdej aktualizacji jest zapisany osobno. Agent nie restartuje systemu. [Wyniki instalacji WUA](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller-install).
5. **Reboot:** GUI pokazuje VM wymagające restartu i prosi o osobne zatwierdzenie. Następna paczka rusza dopiero po potwierdzeniu nowszego czasu rozruchu i dostępności VMware Tools dla poprzedniej. Brak potwierdzenia zatrzymuje kolejne restarty; narzędzie nie wysyła ponownie restartu automatycznie.
6. **Verify:** świeży skan ustala wynik. Operator może rozpocząć kolejną rundę z nowym wyborem albo zakończyć z jawną listą aktualizacji pozostawionych do wykonania. Nie ma automatycznego powtarzania rund.

## Logi, ochrona klastrów i wznowienie

W katalogu `runs/<runId>/` narzędzie zapisuje na bieżąco `run.log` (zdarzenia z czasem, VM i krokiem) oraz `errors.log` (błędy z etapem, kodem i kontekstem). Błąd jest zapisywany od razu, także gdy przebieg kończy się przed raportem. Agent przechowuje własny `agent.log` i `status.json`; kontroler pobiera je do katalogu przebiegu. Po zakończeniu, zatrzymaniu przez operatora lub wznowieniu przerwanego przebiegu powstają `summary.md` i `summary.csv` z wynikiem każdej VM, zainstalowanymi i pominiętymi aktualizacjami, restartami oraz odnośnikami do błędów. GUI ma stale widoczny przycisk **Open logs**. Hasła i wartości poświadczeń nie trafiają do żadnego pliku.

Agent ustala członkostwo w klastrze lokalnie przez `GetNodeClusterState`. Skonfigurowany węzeł jest wykluczony z instalacji i restartu; nierozpoznany stan blokuje VM i trafia do błędów. Kontrola powtarza się przed instalacją i restartem. Sama obecność `ClusSvc` nie oznacza członkostwa. [Dokumentacja Microsoftu](https://learn.microsoft.com/en-us/windows/win32/api/clusapi/nf-clusapi-getnodeclusterstate).

Każdy przebieg ma `runId`, a każdy krok na VM własny `stepId`. Kontroler zapisuje decyzje i postęp atomowo w `run.json`; agent zapisuje wynik w `%ProgramData%\WindowsPatchWizard\<runId>\<stepId>`. Po ponownym otwarciu GUI operator wybiera **Resume run**. Narzędzie pobiera stan agentów i kontynuuje obserwację rozpoczętych prac. Ukończenie wymaga końcowego `status.json` z pasującymi identyfikatorami i `finishedAt`; sam brak procesu nie wystarcza. Niejasny wynik wymaga ręcznego uzgodnienia przed następną instalacją. Zamiar restartu zapisuje się przed wysłaniem polecenia, aby po przerwaniu sprawdzić rozruch bez ryzyka automatycznego wysłania drugiego restartu. [Dane procesu Guest Operations](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.vm.guest.ProcessManager.ProcessInfo.html).

## Implementacja i sprawdzenie

- Zbudować launcher WinForms, kontroler przebiegu, adapter Guest Operations i jeden skrypt gościa z trybami skanowania, instalacji i restartu. Sterowanie procesami prowadzić przez vCenter, a pliki przesyłać przez adresy Guest Operations i `curl.exe`. Opcje certyfikatów stosować wyłącznie do wskazanych kanałów i tylko podczas danego przebiegu. [API transferu vSphere](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.vm.guest.FileManager.html).
- Przed użyciem sprawdzić PowerShell 5.1, import PowerCLI, połączenie z vCenter i ESXi, VMware Tools oraz uprawnienia gościa. Zainstalowany tutaj `VMware.VimAutomation.Core` 13.5 importuje się w 5.1, ale współpracę Guest Operations z docelowym vCenter trzeba potwierdzić pilotażem; aktualny PowerCLI oficjalnie wymaga nowszego PowerShella. [Przewodnik Broadcom](https://developer.broadcom.com/powercli/installation-guide).
- Dodać tylko testy kluczowych zachowań: wybór właściwej VM, wykluczenie klastra, zgodność zatwierdzonych rewizji, zapis błędu i raportu, niezależność obu opcji certyfikatów oraz brak podwójnej instalacji i restartu po wznowieniu. Testów nie uruchamiać przy każdym starcie GUI.
- W pilotażu na nieprodukcyjnej VM przejść skan, instalację, restart i kontrolę; przerwać GUI podczas instalacji oraz po zleceniu restartu i sprawdzić wznowienie, logi i podsumowanie. Klastra użyć wyłącznie do potwierdzenia wykluczenia.

Poza zakresem pozostają serwery fizyczne, automatyczne łatanie klastrów, praca bez operatora, zmiana polityk aktualizacji i automatyczne wycofywanie poprawek.
