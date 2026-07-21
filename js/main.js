/* =============================================
   AWS UG Security Ecuador — Main JavaScript
   ============================================= */

/* ---------- Navbar scroll effect ---------- */
const navbar = document.getElementById('navbar');

window.addEventListener('scroll', () => {
  navbar.classList.toggle('scrolled', window.scrollY > 60);
});

/* ---------- Mobile menu toggle ---------- */
const mobileMenuBtn = document.getElementById('mobile-menu-btn');
const mobileMenu   = document.getElementById('mobile-menu');
const iconOpen     = document.getElementById('icon-open');
const iconClose    = document.getElementById('icon-close');

mobileMenuBtn.addEventListener('click', () => {
  const isHidden = mobileMenu.classList.toggle('hidden');
  iconOpen.classList.toggle('hidden', !isHidden);
  iconClose.classList.toggle('hidden', isHidden);
});

// Close on link click
mobileMenu.querySelectorAll('a').forEach(link => {
  link.addEventListener('click', () => {
    mobileMenu.classList.add('hidden');
    iconOpen.classList.remove('hidden');
    iconClose.classList.add('hidden');
  });
});

/* ---------- Smooth scroll for anchor links ---------- */
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
  anchor.addEventListener('click', function (e) {
    const href = this.getAttribute('href');
    if (href === '#') return;
    e.preventDefault();
    const target = document.querySelector(href);
    if (!target) return;
    const offset = 80;
    window.scrollTo({ top: target.offsetTop - offset, behavior: 'smooth' });
  });
});

/* ---------- Fade-in on scroll (IntersectionObserver) ---------- */
const fadeEls = document.querySelectorAll('.fade-in');
const fadeObserver = new IntersectionObserver(
  (entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('visible');
        fadeObserver.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.12 }
);
fadeEls.forEach(el => fadeObserver.observe(el));

/* ---------- Active nav link on scroll ---------- */
const sections = document.querySelectorAll('section[id]');

window.addEventListener('scroll', () => {
  const scrollY = window.scrollY + 120;
  sections.forEach(section => {
    const id   = section.getAttribute('id');
    const top  = section.offsetTop;
    const h    = section.offsetHeight;
    const link = document.querySelector(`nav a[href="#${id}"]`);
    if (!link) return;
    if (scrollY >= top && scrollY < top + h) {
      document.querySelectorAll('nav a.nav-link').forEach(l => l.classList.remove('active'));
      link.classList.add('active');
    }
  });
}, { passive: true });

/* ---------- Image fallback handlers (replaces inline onerror) ---------- */
// data-img-fallback: hide img and show next sibling element
document.querySelectorAll('img[data-img-fallback]').forEach(img => {
  img.addEventListener('error', function () {
    this.style.display = 'none';
    const sibling = this.nextElementSibling;
    if (sibling) sibling.style.display = 'flex';
  });
});

// data-img-hide: simply hide the img on error (logo bar)
document.querySelectorAll('img[data-img-hide]').forEach(img => {
  img.addEventListener('error', function () {
    this.style.display = 'none';
  });
});

/* ---------- Event registration modal ---------- */
function openEventModal(eventName) {
  const modal   = document.getElementById('event-modal');
  const titleEl = document.getElementById('modal-event-title');
  if (titleEl) titleEl.textContent = eventName;
  modal.classList.add('active');
  document.body.style.overflow = 'hidden';
  modal.querySelector('input[name="name"]')?.focus();
}

function closeEventModal() {
  const modal = document.getElementById('event-modal');
  modal.classList.remove('active');
  document.body.style.overflow = '';
}

// Close on overlay click
document.getElementById('event-modal').addEventListener('click', function (e) {
  if (e.target === this) closeEventModal();
});

// Close via .js-close-modal buttons (replaces inline onclick="closeEventModal()")
document.querySelectorAll('.js-close-modal').forEach(btn => {
  btn.addEventListener('click', closeEventModal);
});

// Close on Escape key
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeEventModal();
});

/* ---------- Event form submission ---------- */
document.getElementById('event-form').addEventListener('submit', function (e) {
  e.preventDefault();
  const btn      = document.getElementById('submit-btn');
  const original = btn.textContent;

  btn.textContent = 'REGISTRO_CONFIRMADO ✓';
  btn.style.background = 'linear-gradient(135deg, #22c55e, #16a34a)';
  btn.disabled = true;

  setTimeout(() => {
    closeEventModal();
    btn.textContent = original;
    btn.style.background = '';
    btn.disabled = false;
    this.reset();
  }, 2200);
});

/* ---------- Expose modal helpers globally ---------- */
window.openEventModal  = openEventModal;
window.closeEventModal = closeEventModal;
