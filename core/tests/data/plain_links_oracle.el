;;; plain_links_oracle.el --- 从 Org 提取裸链接边界参考值 -*- lexical-binding: t; -*-
(require 'org)
(require 'org-element)
(require 'json)
(let* ((target (expand-file-name "plain_links_emacs.json" (file-name-directory load-file-name)))
       (json-array-type 'list)
       (json-object-type 'alist)
       (cases (alist-get 'cases (json-read-file target))))
  (dolist (case cases)
    (with-temp-buffer
      (insert (alist-get 'source case))
      (delay-mode-hooks (org-mode))
      (let* ((org-element-use-cache nil)
             (links
              (org-element-map (org-element-parse-buffer) 'link
                (lambda (link)
                  (when (and (memq (org-element-property :format link) '(plain angle))
                             (member (org-element-property :type link) '("http" "https")))
                    `((target . ,(concat (org-element-property :type link) ":"
                                         (org-element-property :path link)))
                      (start . ,(1- (position-bytes (org-element-property :begin link))))
                      (end . ,(1- (position-bytes
                                  (- (org-element-property :end link)
                                     (org-element-property :post-blank link)))))))))))
        (if (assq 'links case)
            (setcdr (assq 'links case) (vconcat links))
          (nconc case (list (cons 'links (vconcat links))))))))
  (with-temp-file target
    (insert (json-encode `((reference . "(org) External Links; org-link-plain-re; org-element-link-parser")
                           (orgVersion . ,(org-version))
                           (cases . ,(vconcat cases)))))
    (let ((json-array-type 'vector)) (json-pretty-print-buffer))))
