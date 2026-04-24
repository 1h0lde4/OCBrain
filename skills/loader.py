import os

class SkillLoader:
    def load_repo(self, path, skill_type):
        for root, _, files in os.walk(path):
            for f in files:
                if f.endswith(".md"):
                    with open(os.path.join(root, f)) as file:
                        text = file.read()
                        yield text, skill_type
