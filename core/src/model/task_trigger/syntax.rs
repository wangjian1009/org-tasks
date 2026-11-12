//! Org Edna 字符串语法：参数保留字符串与符号区别，禁止执行 Lisp。
use super::{Result, error};

#[derive(Clone, Debug, PartialEq)]
pub(super) enum Value {
    String(String),
    Symbol(String),
    Number(f64, bool),
    List(Vec<Value>),
}
impl Value {
    pub fn text(&self) -> Result<&str> {
        match self {
            Self::String(s) | Self::Symbol(s) => Ok(s),
            _ => Err(error("参数必须为字符串或符号")),
        }
    }
    pub fn number(&self) -> Option<f64> {
        if let Self::Number(n, _) = self {
            Some(*n)
        } else {
            None
        }
    }
    pub fn symbol(&self) -> Option<&str> {
        if let Self::Symbol(s) = self {
            Some(s)
        } else {
            None
        }
    }
}
#[derive(Clone, Debug)]
pub(super) struct Call {
    pub name: String,
    pub args: Vec<Value>,
}
#[derive(Clone, Debug)]
pub(super) enum Form {
    Call(Call),
    If(Vec<Form>, Vec<Form>, Vec<Form>),
}
struct Parser<'a> {
    s: &'a str,
    at: usize,
    nesting: usize,
}
impl Parser<'_> {
    fn space(&mut self) {
        while self.s[self.at..].starts_with(char::is_whitespace) {
            self.at += self.s[self.at..].chars().next().unwrap().len_utf8();
        }
    }
    fn value(&mut self) -> Result<Value> {
        self.space();
        match self.s.as_bytes().get(self.at) {
            Some(b'"') => {
                self.at += 1;
                let mut out = String::new();
                while let Some(c) = self.s[self.at..].chars().next() {
                    self.at += c.len_utf8();
                    match c {
                        '"' => return Ok(Value::String(out)),
                        '\\' => {
                            let c = self.s[self.at..]
                                .chars()
                                .next()
                                .ok_or(error("字符串转义未结束"))?;
                            self.at += c.len_utf8();
                            out.push(match c {
                                'n' => '\n',
                                't' => '\t',
                                'r' => '\r',
                                _ => c,
                            });
                        }
                        _ => out.push(c),
                    }
                }
                Err(error("字符串未结束"))
            }
            Some(b'(') => {
                if self.nesting >= 64 {
                    return Err(error("参数嵌套过深"));
                }
                self.nesting += 1;
                self.at += 1;
                let mut args = Vec::new();
                loop {
                    self.space();
                    if self.s.as_bytes().get(self.at) == Some(&b')') {
                        self.at += 1;
                        break;
                    }
                    if self.at == self.s.len() {
                        return Err(error("参数括号未结束"));
                    }
                    args.push(self.value()?);
                }
                self.nesting -= 1;
                Ok(Value::List(args))
            }
            Some(_) => {
                let start = self.at;
                while let Some(c) = self.s[self.at..].chars().next() {
                    if c.is_whitespace() || matches!(c, '(' | ')' | '"') {
                        break;
                    }
                    self.at += c.len_utf8();
                }
                if start == self.at {
                    return Err(error("无效参数"));
                }
                let value = &self.s[start..self.at];
                Ok(
                    if let Some(n) = value.parse::<f64>().ok().filter(|n| n.is_finite()) {
                        Value::Number(n, value.parse::<i64>().is_ok())
                    } else {
                        Value::Symbol(value.into())
                    },
                )
            }
            None => Err(error("缺少参数")),
        }
    }
    fn forms(&mut self, end: &[&str], depth: usize) -> Result<(Vec<Form>, Option<String>)> {
        if depth > 64 {
            return Err(error("条件嵌套过深"));
        }
        let mut out = Vec::new();
        loop {
            self.space();
            if self.at == self.s.len() {
                return Ok((out, None));
            }
            let Value::Symbol(name) = self.value()? else {
                return Err(error("缺少规则名称"));
            };
            if end.contains(&name.as_str()) {
                return Ok((out, Some(name)));
            }
            if name == "if" {
                let (condition, term) = self.forms(&["then"], depth + 1)?;
                if term.is_none() {
                    return Err(error("if 缺少 then"));
                }
                let (yes, term) = self.forms(&["else", "endif"], depth + 1)?;
                let no = if term.as_deref() == Some("else") {
                    let (no, term) = self.forms(&["endif"], depth + 1)?;
                    if term.is_none() {
                        return Err(error("if 缺少 endif"));
                    }
                    no
                } else if term.is_some() {
                    Vec::new()
                } else {
                    return Err(error("if 缺少 endif"));
                };
                out.push(Form::If(condition, yes, no));
            } else {
                if ["then", "else", "endif"].contains(&name.as_str()) {
                    return Err(error("条件结束标记位置错误"));
                }
                // 与 Edna 一致，函数名后紧接括号才是参数。
                let args = if self.s.as_bytes().get(self.at) == Some(&b'(') {
                    let Value::List(args) = self.value()? else {
                        unreachable!()
                    };
                    args
                } else {
                    Vec::new()
                };
                out.push(Form::Call(Call { name, args }));
            }
        }
    }
}
pub(super) fn parse(s: &str) -> Result<Vec<Form>> {
    let (forms, _) = Parser {
        s,
        at: 0,
        nesting: 0,
    }
    .forms(&[], 0)?;
    validate(&forms, false)?;
    Ok(forms)
}
fn validate(forms: &[Form], condition: bool) -> Result<()> {
    for form in forms {
        match form {
            Form::If(c, y, n) => {
                validate(c, true)?;
                validate(y, condition)?;
                validate(n, condition)?;
            }
            Form::Call(call) => {
                let name = call.name.trim_start_matches('!');
                if (name.ends_with('?') && !condition) || (name.ends_with('!') && condition) {
                    return Err(error("动作与条件不能用于此上下文"));
                }
            }
        }
    }
    Ok(())
}
pub(super) fn is_finder(name: &str) -> bool {
    [
        "self",
        "ids",
        "match",
        "relatives",
        "chain-find",
        "siblings",
        "rest-of-siblings",
        "rest-of-siblings-wrap",
        "siblings-wrap",
        "next-sibling",
        "next-sibling-wrap",
        "previous-sibling",
        "previous-sibling-wrap",
        "first-child",
        "children",
        "parent",
        "descendants",
        "ancestors",
        "olp",
        "file",
        "org-file",
    ]
    .contains(&name)
}
