vercmp.o: vercmp.c
	cc vercmp.c -o vercmp.o

ifneq ($(DESTDIR),)

install: $(DESTDIR)/usr/bin/vercmp fetchers scripts

fetchers: $(DESTDIR)/etc/lpkg.d/fetchers/01_http.sh $(DESTDIR)/etc/lpkg.d/fetchers/02_https.sh
$(DESTDIR)/etc/lpkg.d/fetchers/01_http.sh: fetchers/http.sh
	install -m 0700 -D fetchers/http.sh $(DESTDIR)/etc/lpkg.d/fetchers/01_http.sh
$(DESTDIR)/etc/lpkg.d/fetchers/02_https.sh: fetchers/https.sh
	install -m 0700 -D fetchers/https.sh $(DESTDIR)/etc/lpkg.d/fetchers/02_https.sh

scripts: $(DESTDIR)/usr/bin/lpkg $(DESTDIR)/usr/bin/lpkg-inst $(DESTDIR)/usr/bin/lpkg-alt $(DESTDIR)/usr/bin/lpkg-rm
$(DESTDIR)/usr/bin/lpkg: lpkg.sh
	install -m 0700 -D lpkg.sh $(DESTDIR)/usr/bin/lpkg
$(DESTDIR)/usr/bin/lpkg-inst: inst.sh
	install -m 0700 -D inst.sh $(DESTDIR)/usr/bin/lpkg-inst
$(DESTDIR)/usr/bin/lpkg-alt: alternative.sh
	install -m 0700 -D alternative.sh $(DESTDIR)/usr/bin/lpkg-alt
$(DESTDIR)/usr/bin/lpkg-rm: rm.sh
	install -m 0700 -D rm.sh $(DESTDIR)/usr/bin/lpkg-rm

$(DESTDIR)/usr/bin/vercmp: vercmp.o
	install -m 0700 -D vercmp.o $(DESTDIR)/usr/bin/vercmp

endif
