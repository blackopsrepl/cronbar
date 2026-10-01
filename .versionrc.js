// commit-and-tag-version owns both application version surfaces.
function surface(filename, pattern) {
  return {
    filename,
    updater: {
      readVersion(contents) {
        const match = contents.match(pattern);
        if (!match) throw new Error(`Missing version surface in ${filename}`);
        return match[2];
      },
      writeVersion(contents, version) {
        if (!pattern.test(contents)) throw new Error(`Missing version surface in ${filename}`);
        return contents.replace(pattern, (_, before, old, after) => before + version + after);
      },
    },
  };
}
const library = surface('lib/cronbar.rb', /^(  VERSION = ")([^"\n]+)(")$/m);
const readme = surface('README.md', /^(## Current release: `v)([^`\n]+)(`)$/m);
module.exports = {
  packageFiles: [library],
  bumpFiles: [library, readme],
  tagPrefix: 'v',
  releaseCommitMessageFormat: 'chore(release): {{currentTag}}',
  commitUrlFormat: 'https://github.com/blackopsrepl/cronbar/commit/{{hash}}',
  compareUrlFormat: 'https://github.com/blackopsrepl/cronbar/compare/{{previousTag}}...{{currentTag}}',
  types: ['feat', 'fix', 'perf', 'refactor', 'docs', 'test', 'build', 'ci', 'chore'].map(type => ({
    type, section: { feat: 'Features', fix: 'Bug Fixes' }[type] || type, hidden: false,
  })),
};
