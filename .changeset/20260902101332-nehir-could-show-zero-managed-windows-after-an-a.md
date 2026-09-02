---
"nehir": patch

---

Nehir could show zero managed windows after an auto-update relaunched it before the window server connection was ready — the first scan found nothing and stayed empty until a manual quit-and-reopen. The first scan now retries discovery until it finds your windows. (Complements the busy-desktop scan fix in 1.9.0.)
