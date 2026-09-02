---
"nehir": patch

---

Fixed Nehir only managing one or two windows after restarting onto a busy desktop. When many windows were open, the first scan after launch could time out on apps that were still drawing and drop them; Nehir now re-checks those apps a moment later so a full desktop is picked up completely. Restarting Nehir was the workaround — no longer needed.
