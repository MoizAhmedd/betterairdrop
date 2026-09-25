# site

Takeaways from Maccy, Rectangle, Ice, Dropover, CleanShot and Hazel:

- The hero is the app: its icon, its name, one plain line saying what it does. Hazel says "Automated Organization for Your Mac." and stops.
- Ice gets by on about 95 words. The product does the talking through a real screenshot or a looping video.
- The voice is flat and a little dry ("does one job... Period."). No "reimagined", no adjective triplets.
- The CTA is one download or install action, placed near the top. The GitHub link sits beside it.
- The facts are short fragments ("Free and Open Source, macOS 10.15+"), not whole feature sections.
- They get worse as they grow. Dropover's 2,200 words and testimonial walls are what this page avoids.

## Hosting

GitHub Pages, at https://moizahmedd.github.io/betterairdrop/. `.github/workflows/pages.yml` publishes
`public/` as the site root, with the installer at `/install` and the Sparkle feed at `/appcast.xml`,
on every push to main that touches `site/` and after every release.

Drop a 15-second screen recording at `public/demo.mp4` and it replaces the animated mock.
Preview locally with `python3 -m http.server -d site/public`.
