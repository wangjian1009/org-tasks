// 将面向用户的 Org 原文和索引直接打进应用。
const fs = require('node:fs');
const path = require('node:path');

function writeIfChanged(file, content) {
  if (!fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== content) {
    fs.writeFileSync(file, content);
  }
}

function readHelp(directory, version) {
  const source = fs.readFileSync(path.join(directory, 'index.org'), 'utf8');
  const topics = [...source.matchAll(/^[ \t]*\|[ \t]*([a-z-]+)[ \t]*\|([^|\r\n]+)\|[ \t]*$/gm)]
    .map(([, id, title]) => ({ id, title: title.trim() }));
  const sources = [...source.matchAll(/^- \[\[file:((?:help-[a-z-]+|about)\.org)\]\[/gm)]
    .map(([, file]) => file);
  const articles = sources.map(file => {
    const original = fs.readFileSync(path.join(directory, file), 'utf8');
    const isAbout = file === 'about.org';
    const content = isAbout ? original
      .replaceAll('{{APP_VERSION_NAME}}', () => version.name)
      .replaceAll('{{APP_VERSION_CODE}}', () => String(version.code)) : original;
    const metadata = new Map([...content.split('\n\n', 1)[0].matchAll(/^#\+([A-Z_]+):[ \t]*(.+)$/gm)]
      .map(([, key, value]) => [key, value.trim()]));
    const title = metadata.get('TITLE');
    const summary = metadata.get('DESCRIPTION');
    const topic = isAbout ? '' : metadata.get('HELP_TOPIC');
    if (!title || !summary || (!isAbout && !topics.some(entry => entry.id === topic))) {
      throw new Error(`帮助文章缺少有效的索引信息：${file}`);
    }
    return {
      id: file.slice(0, -4), topic, title, summary, content, file,
      keywords: (metadata.get('KEYWORDS') || '').split(/\s+/).filter(Boolean),
      frequent: metadata.get('HELP_FREQUENT') === 'yes',
    };
  });
  const ids = new Set(articles.map(article => article.id));
  if (!ids.has('about') || ids.size < 2 || ids.size !== articles.length) {
    throw new Error('应用文档索引缺少关于页面、没有帮助文章或包含重复文章');
  }
  const images = new Set();
  for (const { file, content } of articles) {
    for (const [, target] of content.matchAll(/\[\[file:((?:help-[a-z-]+|about)\.org)/g)) {
      if (!sources.includes(target)) throw new Error(`帮助链接未收录：${file} → ${target}`);
    }
    for (const [, image] of content.matchAll(/\[\[file:([\w-]+\.(?:png|jpg|jpeg|webp))\]/g)) {
      images.add(image);
    }
  }
  return { directory, topics, articles, images };
}

function writeHelp(help, output) {
  const { directory, topics, articles, images } = help;
  fs.mkdirSync(output, { recursive: true });
  const files = new Set(['index.json', ...articles.map(article => article.file), ...images]);
  for (const file of fs.readdirSync(output)) {
    if (!files.has(file)) fs.unlinkSync(path.join(output, file));
  }
  for (const { file, content } of articles) writeIfChanged(path.join(output, file), content);
  for (const image of images) fs.copyFileSync(path.join(directory, image), path.join(output, image));
  const index = articles.map(({ content, file, ...entry }) => entry);
  writeIfChanged(path.join(output, 'index.json'), JSON.stringify({ topics, articles: index }) + '\n');
}

module.exports = function prepareHelp(directory, output, appManifest) {
  const { versionName, versionCode } = JSON.parse(fs.readFileSync(appManifest, 'utf8')).app;
  if (typeof versionName !== 'string' || !versionName.trim() || !Number.isSafeInteger(versionCode)) {
    throw new Error('应用清单缺少有效的版本号或构建号');
  }
  const version = { name: versionName, code: versionCode };
  const chinese = readHelp(path.join(directory, 'zh-CN'), version);
  const english = readHelp(path.join(directory, 'en'), version);
  const topicIds = new Set(english.topics.map(topic => topic.id));
  const articlesById = new Map(english.articles.map(article => [article.id, article]));
  if (chinese.topics.length !== topicIds.size || chinese.topics.some(topic => !topicIds.has(topic.id))) {
    throw new Error('中英文帮助目录的主题标识不一致');
  }
  if (chinese.articles.length !== articlesById.size || chinese.articles.some(article => {
    const translation = articlesById.get(article.id);
    return translation?.topic !== article.topic || translation?.frequent !== article.frequent;
  })) {
    throw new Error('中英文帮助目录的文章标识、主题或常见问题设置不一致');
  }
  writeHelp(chinese, path.join(output, 'zh-CN'));
  writeHelp(english, path.join(output, 'en'));
  // 清理旧版生成在帮助资源根目录的索引及文章。
  for (const item of fs.readdirSync(output, { withFileTypes: true })) {
    if (item.isFile() && (item.name === 'index.json' || /^help-[a-z-]+\.org$/.test(item.name))) {
      fs.unlinkSync(path.join(output, item.name));
    }
  }
};
