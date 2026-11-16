import re,sys
# usage: res.py file choice1 choice2 ... (o=ours/HEAD, t=theirs(PR), b=both ours then theirs)
f=sys.argv[1]; ch=sys.argv[2:]
s=open(f).read()
pat=re.compile(r'<<<<<<< [^\n]*\n(.*?)(?:\|\|\|\|\|\|\| [^\n]*\n.*?)?=======\n(.*?)>>>>>>> [^\n]*\n',re.S)
i=[0]
def r(m):
    c=ch[i[0]]; i[0]+=1
    return {'o':m.group(1),'t':m.group(2),'b':m.group(1)+m.group(2)}[c]
s=pat.sub(r,s); open(f,'w').write(s); print(f,i[0])
